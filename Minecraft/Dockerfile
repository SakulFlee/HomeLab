FROM docker.io/eclipse-temurin:21

ARG MINECRAFT_VERSION="1.21.6"
ARG PAPER_BUILD="46"

EXPOSE 25565

RUN mkdir /app
RUN curl -L -o /paper.jar https://api.papermc.io/v2/projects/paper/versions/${MINECRAFT_VERSION}/builds/${PAPER_BUILD}/downloads/paper-${MINECRAFT_VERSION}-${PAPER_BUILD}.jar

ENTRYPOINT ["sh", "-c", "mkdir /app; cd /app && java -jar /paper.jar"]
