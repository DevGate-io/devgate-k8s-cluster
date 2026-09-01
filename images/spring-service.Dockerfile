# Общий образ для Spring Boot-сервисов: берёт заранее собранный fat-jar.
# Сборка: make -C k8s build (контекст — корень сервиса, JAR_FILE — путь к jar).
FROM amazoncorretto:21-alpine

ARG JAR_FILE
COPY ${JAR_FILE} /app/app.jar

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0"

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
