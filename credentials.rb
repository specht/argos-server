WEBSITE_HOST = 'argus.nhcham.org'
LETSENCRYPT_EMAIL = 'specht@gymnasiumsteglitz.de'

WEB_ROOT = ENV['DEVELOPMENT'] ? 'http://localhost:8035' : "https://#{WEBSITE_HOST}"
