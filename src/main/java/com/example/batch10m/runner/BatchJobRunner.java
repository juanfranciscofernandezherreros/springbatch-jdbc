package com.example.batch10m.runner;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.batch.core.BatchStatus;
import org.springframework.batch.core.Job;
import org.springframework.batch.core.JobExecution;
import org.springframework.batch.core.JobParameters;
import org.springframework.batch.core.JobParametersBuilder;
import org.springframework.batch.core.launch.JobLauncher;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

@Component
public class BatchJobRunner implements ApplicationRunner {
    private static final Logger log = LoggerFactory.getLogger(BatchJobRunner.class);
    private final JobLauncher jobLauncher;
    private final Job job;
    private final boolean run;
    private final String jobKey;

    public BatchJobRunner(JobLauncher jobLauncher,
                          Job processEventsJob,
                          @Value("${app.run:false}") boolean run,
                          @Value("${app.job-key:}") String jobKey) {
        this.jobLauncher = jobLauncher;
        this.job = processEventsJob;
        this.run = run;
        this.jobKey = jobKey;
    }

    @Override
    public void run(ApplicationArguments args) throws Exception {
        if (!run) {
            log.info("Job no lanzado. Usa --app.run=true --app.job-key=mi-lote");
            return;
        }
        if (jobKey.isBlank()) {
            throw new IllegalArgumentException("Falta --app.job-key (identificador estable para reiniciar)");
        }
        JobParameters parameters = new JobParametersBuilder()
                .addString("runKey", jobKey, true)
                .toJobParameters();
        log.info("Iniciando job con runKey={}", jobKey);
        JobExecution execution = jobLauncher.run(job, parameters);
        if (execution.getStatus() != BatchStatus.COMPLETED) {
            throw new IllegalStateException("El job terminó en " + execution.getStatus()
                    + "; relánzalo con la MISMA app.job-key para reanudar");
        }
    }
}
