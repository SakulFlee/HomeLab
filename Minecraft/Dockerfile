FROM eclipse-temurin:21

ARG MINECRAFT_VERSION="1.21.6"
ARG PAPER_BUILD="46"

RUN mkdir /app
RUN curl -L -o /app/server.jar https://api.papermc.io/v2/projects/paper/versions/${MINECRAFT_VERSION}/builds/${PAPER_BUILD}/downloads/paper-${MINECRAFT_VERSION}-${PAPER_BUILD}.jar
RUN echo "eula=true" > /app/eula.txt

ENTRYPOINT ["java", "-jar", "/app/server.jar"]
