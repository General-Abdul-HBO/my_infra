package com.example.app;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

@RestController
public class GreetingController {

    private static final long MAX_DELAY_MS = 5_000;

    private final AppProperties properties;
    private final String version;
    private final String hostname;

    public GreetingController(AppProperties properties, ObjectProvider<BuildProperties> buildProperties) {
        this.properties = properties;
        BuildProperties build = buildProperties.getIfAvailable();
        this.version = build != null ? build.getVersion() : "dev";
        this.hostname = resolveHostname();
    }

    /** Which version is running, and on which pod - handy when watching a rolling update. */
    @GetMapping("/")
    public Map<String, String> info() {
        Map<String, String> body = new LinkedHashMap<>();
        body.put("app", "example-app");
        body.put("version", version);
        body.put("environment", properties.environment());
        body.put("pod", hostname);
        return body;
    }

    @GetMapping("/api/greeting")
    public Map<String, String> greeting(@RequestParam(defaultValue = "World") String name) {
        return Map.of("message", properties.greeting() + ", " + name + "!");
    }

    /** Always fails with HTTP 500 - use it to trigger the error-rate alert. */
    @GetMapping("/api/simulate-error")
    public Map<String, String> simulateError() {
        throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "Simulated failure");
    }

    /** Responds after a delay - use it to move the latency graphs and alert. */
    @GetMapping("/api/slow")
    public Map<String, Object> slow(@RequestParam(defaultValue = "1000") long ms) throws InterruptedException {
        long delay = Math.max(0, Math.min(ms, MAX_DELAY_MS));
        Thread.sleep(delay);
        return Map.of("sleptMs", delay);
    }

    private static String resolveHostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }
}
