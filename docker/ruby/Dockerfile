FROM ruby:2-alpine
MAINTAINER Dr. Michael Specht <specht@quelltextschmiede.de>

RUN apk update && apk upgrade
RUN apk add curl bash curl-dev ruby-dev git build-base tzdata && \
    rm -rf /var/cache/apk/*
RUN cp /usr/share/zoneinfo/Europe/Berlin /etc/localtime && echo "Europe/Berlin" > /etc/timezone
RUN gem install bundler
ADD Gemfile /
RUN bundle install
ADD credentials.rb /
RUN adduser -D -u 1000 michael
USER michael
