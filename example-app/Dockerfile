# syntax=docker/dockerfile:1

# ---- Build stage: compile, run the tests, package the jar --------------------
FROM maven:3.9-eclipse-temurin-26 AS build
WORKDIR /workspace

# Copy only the POM first so the dependency download is cached as its own
# layer - it's skipped on rebuilds unless pom.xml changes.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp dependency:go-offline

COPY src ./src
# Tests run here by default (local builds). The CI pipeline has already run
# them - plus the SonarQube scan - in an earlier job, so it passes
# --build-arg SKIP_TESTS=true to avoid running them twice.
ARG SKIP_TESTS=false
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp package -DskipTests=${SKIP_TESTS}

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

# Which Git commit this image was built from: CI passes --build-arg GIT_SHA=...
# The app reports it at GET / (APP_COMMIT -> app.commit), and the OCI label
# lets you trace any running image back to its source.
ARG GIT_SHA=local
ENV APP_COMMIT=${GIT_SHA}
LABEL org.opencontainers.image.revision=${GIT_SHA} \
      org.opencontainers.image.title=example-app

ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]
