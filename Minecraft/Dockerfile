FROM docker.io/eclipse-temurin:24

ARG MINECRAFT_VERSION="1.21.7"
ARG PAPER_BUILD="9"

EXPOSE 25565
EXPOSE 19132
EXPOSE 8100

# Dependencies & Updates
RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install -y sqlite3
RUN apt-get install -y libsqljet-java
RUN apt-get install -y libxerial-sqlite-jdbc-java

# Server
RUN mkdir /app
RUN curl -L -o /paper.jar https://api.papermc.io/v2/projects/paper/versions/${MINECRAFT_VERSION}/builds/${PAPER_BUILD}/downloads/paper-${MINECRAFT_VERSION}-${PAPER_BUILD}.jar

# Plugins
COPY plugins /plugins

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
