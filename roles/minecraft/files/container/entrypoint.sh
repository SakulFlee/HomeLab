#!/usr/bin/env sh

# Create app dir if it doesn't exist yet and change into it
mkdir /app
cd /app

# Remove any plugin JAR files, then copy out in-image plugins
rm -f plugins/*.jar
cp /plugins/* plugins/

# EULA
echo "eula=true" >/app/eula.txt

# Start the server! :)
java -Xms512M -Xmx4G -jar /paper.jar
