# Compilación y pruebas unitarias en la fase de construcción
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /workspace
COPY pom.xml ./
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp clean package

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd --system --uid 10001 batchuser
COPY --from=builder /workspace/target/spring-batch-10m-1.0.0.jar /app/app.jar
USER batchuser
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
