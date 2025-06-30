FROM docker.io/eclipse-temurin:21

ARG MINECRAFT_VERSION="1.21.7"
ARG PAPER_BUILD="9"

EXPOSE 25565
EXPOSE 19132
EXPOSE 8100

# Dependencies & Updates
RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install -y sqlite3

# Server
RUN mkdir /app
RUN curl -L -o /paper.jar https://api.papermc.io/v2/projects/paper/versions/${MINECRAFT_VERSION}/builds/${PAPER_BUILD}/downloads/paper-${MINECRAFT_VERSION}-${PAPER_BUILD}.jar

# Plugins
RUN mkdir /plugins
RUN curl -L -o /plugins/Geyser.jar https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
RUN curl -L -o /plugins/FloodGate.jar https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
RUN curl -L -o /plugins/ViaVersion.jar https://hangarcdn.papermc.io/plugins/ViaVersion/ViaVersion/versions/5.4.1/PAPER/ViaVersion-5.4.1.jar
RUN curl -L -o /plugins/ViaBackwards.jar https://hangarcdn.papermc.io/plugins/ViaVersion/ViaBackwards/versions/5.4.1/PAPER/ViaBackwards-5.4.1.jar
RUN curl -L -o /plugins/Chunky.jar https://hangarcdn.papermc.io/plugins/pop4959/Chunky/versions/1.4.40/PAPER/Chunky-Bukkit-1.4.40.jar
RUN curl -L -o /plugins/Portalis.jar https://hangarcdn.papermc.io/plugins/KingTheGuy/Portalis/versions/1.0/PAPER/portalis-1.0.jar
RUN curl -L -o /plugins/TeaksTweaks.jar https://hangarcdn.papermc.io/plugins/teakivy/TeaksTweaks/versions/2.0.8-mc1.21.5/PAPER/TeaksTweaks-v2.0.8-mc1.21.5.jar
RUN curl -L -o /plugins/TreeChopper.jar https://github.com/BeanFeed/TreeChopper/releases/tag/v1.1

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
