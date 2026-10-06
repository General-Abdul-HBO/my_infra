package com.example.app;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Settings under the "app." prefix. Defaults live in application.properties;
 * in Kubernetes they're overridden by environment variables:
 * APP_GREETING / APP_ENVIRONMENT come from the ConfigMap, and APP_COMMIT is
 * baked into the image by the CI pipeline (the Git commit it was built from).
 */
@ConfigurationProperties(prefix = "app")
public record AppProperties(String greeting, String environment, String commit) {
}
