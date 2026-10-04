package com.example.app;

import static org.hamcrest.Matchers.is;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = "app.greeting=Hi")
@AutoConfigureMockMvc
class AppTest {

    @Autowired
    private MockMvc mvc;

    @Test
    void infoReportsAppNameAndVersion() throws Exception {
        mvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.app", is("example-app")))
                .andExpect(jsonPath("$.version", is("0.1.0")));
    }

    @Test
    void greetingUsesConfiguredGreeting() throws Exception {
        mvc.perform(get("/api/greeting").param("name", "DevOps"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.message", is("Hi, DevOps!")));
    }

    @Test
    void greetingDefaultsToWorld() throws Exception {
        mvc.perform(get("/api/greeting"))
                .andExpect(jsonPath("$.message", is("Hi, World!")));
    }

    @Test
    void simulateErrorReturns500() throws Exception {
        mvc.perform(get("/api/simulate-error"))
                .andExpect(status().isInternalServerError());
    }

    @Test
    void slowCapsTheDelay() throws Exception {
        mvc.perform(get("/api/slow").param("ms", "-5"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.sleptMs", is(0)));
    }
}
