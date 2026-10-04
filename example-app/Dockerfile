# syntax=docker/dockerfile:1

# ---- Build stage: compile, run the tests, package the jar --------------------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /workspace

# Copy only the POM first so the dependency download is cached as its own
# layer - it's skipped on rebuilds unless pom.xml changes.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp dependency:go-offline

COPY src ./src
# Tests run here. Once the CI pipeline exists, it runs them before this build.
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp package

# Split the fat jar into layers (dependencies change rarely, our code often),
# so image pushes/pulls only move the small changed layer.
RUN java -Djarmode=tools -jar target/example-app.jar extract --layers --launcher --destination target/extracted

# ---- Runtime stage: JRE only, no Maven, no source code -----------------------
FROM eclipse-temurin:21-jre-alpine

# Fixed numeric UID/GID: Kubernetes can then verify runAsNonRoot.
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app -H -s /sbin/nologin app

WORKDIR /app
COPY --from=build /workspace/target/extracted/dependencies/ ./
COPY --from=build /workspace/target/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/target/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/target/extracted/application/ ./

USER 10001:10001
EXPOSE 8080 8081

# Size the heap from the container memory limit, and exit (so Kubernetes
# restarts the pod) instead of limping along after an OutOfMemoryError.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
