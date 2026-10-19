package com.example.batch10m.config;

import com.example.batch10m.domain.ProcessedEvent;
import com.example.batch10m.domain.SourceEvent;
import com.example.batch10m.partition.IdRangePartitioner;
import com.example.batch10m.processing.EventProcessor;
import com.example.batch10m.processing.InvalidEventException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.ChunkListener;
import org.springframework.batch.core.scope.context.ChunkContext;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobExecutionListener;
import org.springframework.batch.core.Step;
import org.springframework.batch.core.StepExecution;
import org.springframework.batch.core.SkipListener;
import org.springframework.batch.core.configuration.annotation.StepScope;
import org.springframework.batch.core.job.builder.JobBuilder;
import org.springframework.batch.core.repository.JobRepository;
import org.springframework.batch.core.step.builder.StepBuilder;
import org.springframework.batch.item.ItemProcessor;
import org.springframework.batch.item.database.JdbcPagingItemReader;
import org.springframework.batch.item.database.JdbcBatchItemWriter;
import org.springframework.batch.item.database.builder.JdbcBatchItemWriterBuilder;
import org.springframework.batch.item.database.builder.JdbcPagingItemReaderBuilder;
import org.springframework.batch.item.database.Order;
import org.springframework.batch.item.database.support.PostgresPagingQueryProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.task.TaskExecutor;
import org.springframework.dao.TransientDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;
import org.springframework.transaction.PlatformTransactionManager;

import javax.sql.DataSource;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;

@Configuration(proxyBeanMethods = false)
public class BatchConfiguration {
    private static final Logger log = LoggerFactory.getLogger(BatchConfiguration.class);

    @Bean
    IdRangePartitioner idRangePartitioner(JdbcTemplate jdbcTemplate) {
        return new IdRangePartitioner(jdbcTemplate);
    }

    @Bean
    TaskExecutor partitionTaskExecutor(@Value("${app.batch.threads:4}") int threads) {
        if (threads < 1) throw new IllegalArgumentException("BATCH_THREADS debe ser >= 1");
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(threads);
        executor.setMaxPoolSize(threads);
        executor.setQueueCapacity(100);
        executor.setThreadNamePrefix("batch-worker-");
        executor.setWaitForTasksToCompleteOnShutdown(true);
        executor.initialize();
        return executor;
    }

    @Bean
    @StepScope
    JdbcPagingItemReader<SourceEvent> sourceReader(
            DataSource dataSource,
            @Value("#{stepExecutionContext['minId']}") Long minId,
            @Value("#{stepExecutionContext['maxId']}") Long maxId,
            @Value("${app.batch.page-size:1000}") int pageSize) {
        PostgresPagingQueryProvider queryProvider = new PostgresPagingQueryProvider();
        queryProvider.setSelectClause("SELECT id, customer_id, amount, category, created_at");
        queryProvider.setFromClause("FROM source_events");
        queryProvider.setWhereClause("WHERE id BETWEEN :minId AND :maxId");
        Map<String, Order> sorting = new LinkedHashMap<>();
        sorting.put("id", Order.ASCENDING);
        queryProvider.setSortKeys(sorting);

        return new JdbcPagingItemReaderBuilder<SourceEvent>()
                .name("sourceEventsPagingReader")
                .dataSource(dataSource)
                .queryProvider(queryProvider)
                .parameterValues(Map.of("minId", minId, "maxId", maxId))
                .pageSize(pageSize)
                .rowMapper((rs, rowNum) -> mapEvent(rs))
                .saveState(true)
                .build();
    }

    private static SourceEvent mapEvent(ResultSet rs) throws SQLException {
        return new SourceEvent(
                rs.getLong("id"),
                rs.getLong("customer_id"),
                rs.getBigDecimal("amount"),
                rs.getString("category"),
                rs.getObject("created_at", java.time.OffsetDateTime.class));
    }

    @Bean
    ItemProcessor<SourceEvent, ProcessedEvent> eventProcessor(
            @Value("${app.batch.fail-at-id:0}") long failAtId) {
        return new EventProcessor(failAtId);
    }

    @Bean
    JdbcBatchItemWriter<ProcessedEvent> processedEventWriter(DataSource dataSource) {
        String sql = """
                INSERT INTO processed_events
                  (id, customer_id, amount, category, amount_band, created_at, processed_at)
                VALUES (:id, :customerId, :amount, :category, :amountBand, :createdAt, now())
                ON CONFLICT (id) DO UPDATE SET
                  customer_id = EXCLUDED.customer_id,
                  amount = EXCLUDED.amount,
                  category = EXCLUDED.category,
                  amount_band = EXCLUDED.amount_band,
                  created_at = EXCLUDED.created_at,
                  processed_at = now()
                """;
        return new JdbcBatchItemWriterBuilder<ProcessedEvent>()
                .dataSource(dataSource)
                .sql(sql)
                .itemSqlParameterSourceProvider(item -> new MapSqlParameterSource()
                        .addValue("id", item.id())
                        .addValue("customerId", item.customerId())
                        .addValue("amount", item.amount())
                        .addValue("category", item.category())
                        .addValue("amountBand", item.amountBand())
                        .addValue("createdAt", item.createdAt()))
                .assertUpdates(false)
                .build();
    }

    @Bean
    SkipListener<SourceEvent, ProcessedEvent> rejectedEventListener(JdbcTemplate jdbcTemplate) {
        return new SkipListener<>() {
            @Override
            public void onSkipInProcess(SourceEvent item, Throwable cause) {
                String message = cause.getMessage() == null ? cause.getClass().getSimpleName() : cause.getMessage();
                if (message.length() > 1000) message = message.substring(0, 1000);
                jdbcTemplate.update("""
                        INSERT INTO rejected_events(event_id, reason, rejected_at)
                        VALUES (?, ?, now())
                        ON CONFLICT(event_id) DO UPDATE SET
                          reason = EXCLUDED.reason, rejected_at = now()
                        """, item.id(), message);
                log.warn("Evento descartado (registrado en rejected_events): id={}, motivo={}", item.id(), message);
            }
        };
    }

    @Bean
    ChunkListener chunkProgressListener() {
        return new ChunkListener() {
            @Override
            public void afterChunk(ChunkContext context) {
                StepExecution step = context.getStepContext().getStepExecution();
                long reads = step.getReadCount();
                if (reads > 0 && reads % 100_000 == 0) {
                    log.info("PROGRESO partición={} leídos={} escritos={}",
                            step.getStepName(), reads, step.getWriteCount());
                }
            }
        };
    }

    @Bean
    Step workerStep(JobRepository jobRepository,
                    PlatformTransactionManager transactionManager,
                    JdbcPagingItemReader<SourceEvent> sourceReader,
                    ItemProcessor<SourceEvent, ProcessedEvent> eventProcessor,
                    JdbcBatchItemWriter<ProcessedEvent> processedEventWriter,
                    SkipListener<SourceEvent, ProcessedEvent> rejectedEventListener,
                    ChunkListener chunkProgressListener,
                    @Value("${app.batch.chunk-size:500}") int chunkSize,
                    @Value("${app.batch.max-skips:0}") int maxSkips) {
        return new StepBuilder("workerStep", jobRepository)
                .<SourceEvent, ProcessedEvent>chunk(chunkSize, transactionManager)
                .reader(sourceReader)
                .processor(eventProcessor)
                .writer(processedEventWriter)
                .faultTolerant()
                .retry(TransientDataAccessException.class)
                .retryLimit(3)
                .skip(InvalidEventException.class)
                .skipLimit(maxSkips)
                .listener(rejectedEventListener)
                .listener(chunkProgressListener)
                .build();
    }

    @Bean
    Step managerStep(JobRepository jobRepository,
                     Step workerStep,
                     IdRangePartitioner idRangePartitioner,
                     TaskExecutor partitionTaskExecutor,
                     @Value("${app.batch.grid-size:8}") int gridSize) {
        return new StepBuilder("managerStep", jobRepository)
                .partitioner("workerStep", idRangePartitioner)
                .step(workerStep)
                .gridSize(gridSize)
                .taskExecutor(partitionTaskExecutor)
                .build();
    }

    @Bean
    Job processEventsJob(JobRepository jobRepository, Step managerStep) {
        return new JobBuilder("processEventsJob", jobRepository)
                .listener(new JobExecutionListener() {
                    @Override
                    public void afterJob(JobExecution jobExecution) {
                        // El manager agrega los contadores de los workers:
                        // incluirlo duplicaba readCount y writeCount.
                        long read = 0, written = 0, skipped = 0;
                        for (StepExecution step : jobExecution.getStepExecutions()) {
                            if (step.getStepName().startsWith("workerStep:")) {
                                read += step.getReadCount();
                                written += step.getWriteCount();
                                skipped += step.getSkipCount();
                            }
                        }
                        long durationMs = jobExecution.getStartTime() != null
                                && jobExecution.getEndTime() != null
                                ? Math.max(1, java.time.Duration.between(
                                        jobExecution.getStartTime(), jobExecution.getEndTime()).toMillis())
                                : 0;
                        long throughput = durationMs > 0 ? Math.round(written * 1000d / durationMs) : 0;
                        long heapPeakMiB = java.lang.management.ManagementFactory.getMemoryPoolMXBeans()
                                .stream()
                                .filter(pool -> pool.getType() == java.lang.management.MemoryType.HEAP)
                                .mapToLong(pool -> pool.getPeakUsage() == null
                                        ? 0 : pool.getPeakUsage().getUsed())
                                .sum() / (1024L * 1024L);
                        log.info("RESULTADO jobKey={} estado={} leídos={} escritos={} descartados={}",
                                jobExecution.getJobParameters().getString("runKey"),
                                jobExecution.getStatus(), read, written, skipped);
                        // Formato fijo parseable por el benchmark de Windows y Linux.
                        log.info("PERF_RESULT durationMs={} recordsRead={} recordsWritten={} skipped={} recordsPerSecond={} heapPeakMiB={} status={}",
                                durationMs, read, written, skipped, throughput,
                                heapPeakMiB, jobExecution.getStatus());
                    }
                })
                .start(managerStep)
                .build();
    }
}
