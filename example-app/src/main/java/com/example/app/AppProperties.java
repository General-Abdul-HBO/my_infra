package com.example.app;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Settings under the "app." prefix. Defaults live in application.properties;
 * in Kubernetes they're overridden by environment variables from the
 * ConfigMap (APP_GREETING -> app.greeting, APP_ENVIRONMENT -> app.environment).
 */
@ConfigurationProperties(prefix = "app")
public record AppProperties(String greeting, String environment) {
}
