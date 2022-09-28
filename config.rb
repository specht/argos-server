#!/usr/bin/env ruby

STAGING = File::dirname(File::expand_path(__FILE__)).include?('staging')

require 'fileutils'
require 'json'
require 'yaml'
require './credentials.rb'

PROFILE = [:static, :dynamic]

# to get development mode, add the following to your ~/.bashrc:
# export QTS_DEVELOPMENT=1

DEVELOPMENT    = !(ENV['QTS_DEVELOPMENT'].nil?)
PROJECT_NAME = 'argos' + (DEVELOPMENT ? 'dev' : '')
DEV_NGINX_PORT = 8035
LOGS_PATH = DEVELOPMENT ? './logs' : "/home/qts/logs/#{PROJECT_NAME}#{STAGING ? '_staging' : ''}"
DATA_PATH = DEVELOPMENT ? './data' : "/home/qts/data/#{PROJECT_NAME}#{STAGING ? '_staging' : ''}"
RAW_FILES_PATH = File::join(DATA_PATH, 'raw')
GEN_FILES_PATH = File::join(DATA_PATH, 'gen')

docker_compose = {
    :version => '3',
    :services => {},
}

if PROFILE.include?(:static)
    docker_compose[:services][:nginx] = {
        :build => './docker/nginx',
        :volumes => [
            './src/static:/usr/share/nginx/html:ro',
            "#{RAW_FILES_PATH}:/raw:ro",
            "#{GEN_FILES_PATH}:/gen:ro",
            "#{LOGS_PATH}:/var/log/nginx",
        ]
    }
    #docker_compose[:services][:php] = {
    #    :build => './docker/php',
    #    :volumes => [
    #        './src/static:/var/www/html:ro',
    #        "#{PHP_LOGS_PATH}:/var/log/php",
    #    ]
    #}
    if !DEVELOPMENT
       docker_compose[:services][:nginx][:environment] = [
           "VIRTUAL_HOST=#{WEBSITE_HOST}",
           "LETSENCRYPT_HOST=#{WEBSITE_HOST}",
           "LETSENCRYPT_EMAIL=#{LETSENCRYPT_EMAIL}"
       ]
       docker_compose[:services][:nginx][:expose] = ['80']
    end
       
    if PROFILE.include?(:dynamic)
        docker_compose[:services][:nginx][:links] = ["ruby:#{PROJECT_NAME}_ruby_1"]
    end
    nginx_config = <<~eos
        log_format custom '$http_x_forwarded_for - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$request_time"';

        server {
            listen 80;
            server_name localhost;
            client_max_body_size 8M;

            access_log /var/log/nginx/access.log custom;

            charset utf-8;

            location /raw/ {
                rewrite ^/raw(.*)$ $1 break;
                root /raw;
            }

            location /gen/ {
                rewrite ^/gen(.*)$ $1 break;
                root /gen;
            }

            location / {
                root /usr/share/nginx/html;
                try_files $uri @ruby;
            }

            location @ruby {
                proxy_pass http://#{PROJECT_NAME}_ruby_1:9292;
                proxy_set_header Host $host;
                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection Upgrade;
            }
        }

    eos
    File::open('docker/nginx/default.conf', 'w') do |f|
        f.write nginx_config
    end
    if PROFILE.include?(:dynamic)
        docker_compose[:services][:nginx][:depends_on] = [:ruby]
    end
end

if PROFILE.include?(:dynamic)
    env = []
    env << 'DEVELOPMENT=1' if DEVELOPMENT
    docker_compose[:services][:ruby] = {
        :build => './docker/ruby',
        :volumes => ['./src/ruby:/app:ro',
                     './src/static:/static:ro',
                     './src/tasks:/tasks:ro',
                     "#{RAW_FILES_PATH}:/raw",
                     "#{DATA_PATH}:/data",
                     "#{GEN_FILES_PATH}:/gen"],
        :environment => env,
        :working_dir => '/app',
        :entrypoint =>  DEVELOPMENT ?
            'rerun -b --dir /app -s SIGKILL \'rackup --host 0.0.0.0\'' :
            'rackup --host 0.0.0.0'
    }
end

docker_compose[:services].values.each do |x|
    x[:network_mode] = 'default'
end

if DEVELOPMENT
    docker_compose[:services][:nginx][:ports] = ["127.0.0.1:#{DEV_NGINX_PORT}:80"]
else
    docker_compose[:services].values.each do |x|
        x[:restart] = :always
    end
end

File::open('docker-compose.yaml', 'w') do |f|
    f.puts "# NOTICE: don't edit this file directly, use config.rb instead!\n"
    f.write(JSON::parse(docker_compose.to_json).to_yaml)
end

FileUtils::mkpath(LOGS_PATH)
if PROFILE.include?(:dynamic)
    FileUtils::cp('src/ruby/Gemfile', 'docker/ruby/')
    FileUtils::cp('credentials.rb', 'docker/ruby/')
    # FileUtils::mkpath(File::join(RAW_FILES_PATH, 'uploads'))
    # FileUtils::mkpath(File::join(RAW_FILES_PATH, 'code'))
    FileUtils::mkpath(GEN_FILES_PATH)
    FileUtils::mkpath(File.join(DATA_PATH, 'temp'))
end

system("docker-compose --project-name #{PROJECT_NAME} #{ARGV.join(' ')}")
