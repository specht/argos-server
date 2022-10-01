# Argos-Server

Dieser Server ist das Backend der [Argos-App](https://github.com/specht/argos).

# Wie kann ich den Server lokal starten?

```
./config.rb build
./config.rb up
```
Hinweis: `config.rb` ist ein Wrapper um `docker-compose`, der die `docker-compose.yaml` generiert und dann die Kommandozeilenargumente an `docker-compose` durchreicht.

# Wie kann ich den Server im Internet starten?

Passe zuerst die Konstanten `WEBSITE_HOST` und `LETSENCRYPT_EMAIL` in `credentials.rb` an, anschließend können die Container erstellt und gestartet werden:

```
./config.rb build
./config.rb up -d
```

Der Server fügt sich nahtlos in einer TLS-Frontend-Umgebung mit [jwilder/nginx-proxy](jwilder/nginx-proxy) und [nginxproxy/acme-companion](https://hub.docker.com/r/nginxproxy/acme-companion) ein.