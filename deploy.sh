#!/bin/bash
# с учетом идей https://medium.com/@pentacent/nginx-and-lets-encrypt-with-docker-in-less-than-5-minutes-b4b8a60d3a71

die () {
    echo >&2 "$@"
    exit 1
}

[ "$#" -ge 2 ] || die "usage: deploy.sh email <domain1 domain2 ...>"

# проверка docker-compose
if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'ОШИБКА: не установлен docker-compose, см. https://docs.docker.com/compose/install/' >&2
  exit 1
fi

# переменные
nginx="./nginx" # Директория Nginx
templates="$nginx/templates" # Директория шаблонов
production="$nginx/production" # Рабочая директория Nginx 
apptemplate="app_template.conf" # Шаблон конфигурации домена для Nginx
upstream="upstream.conf"  # Приложение на Nuxt
rsa_key_size=4096

# установить в 1 для запуска без запроса сертификата, чтобы не делать лишних запросов, иначе = 0
staging=0

# список доменов для Let's Encrypt
domains=(${@:2})

echo "### Запуск контейнеров приложения ..."
sudo docker-compose -f docker-compose.yml up --force-recreate -d
echo

# Замена знака переменной Nginx для использования envsubst
export DOLLAR='$'
conf=".conf"
for domain in "${domains[@]}"; do
  export DOMAIN=$domain
  envsubst < $templates/$apptemplate > $production/$domain$conf
done
cp $templates/$upstream $production

# Установка параметра staging mode для certbot
# if [ $staging != "0" ]; then staging_arg="--staging"; fi


# перевыпуск сертификатов
if [ $staging == "0" ]; then

  # адрес email для Let's Encrypt
  email="$1" 

  # папка с сертификатами Let's Encrypt для Nginx
  cert_path="$production/certbot"

  # проверка что сертификаты уже есть
  if [ -d "$cert_path/conf/live/" ]; then
    read -p "Найдены ранее выданные сертификаты. Продолжить и получить новые сертификаты? (y/N) " decision
    if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
      exit
    fi
    echo
  fi

  # загрузка рекомендуемых параметров TLS
  if [ ! -e "$cert_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$cert_path/conf/ssl-dhparams.pem" ]; then
  echo "### загрузка рекомендуемых параметров TLS ..."
  sudo mkdir -p "$cert_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$cert_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$cert_path/conf/ssl-dhparams.pem"
  #openssl dhparam -out "$cert_path/conf/ssl-dhparams.pem" 2048
  echo
  fi

  # удаление устаревших / ранее выданных сертификатов
  for domain in "${domains[@]}"; do
    echo "### удаление устаревших / ранее выданных сертификатов $domain ..."
    sudo docker-compose -f ./nginx/docker-compose.yml run --rm --entrypoint "\
      rm -Rf /etc/letsencrypt/live/$domain && \
      rm -Rf /etc/letsencrypt/archive/$domain && \
      rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
    echo
  done

  # создание подменных сертификатов, чтобы Nginx стартовал, и их удаление после старта
  for domain in "${domains[@]}"; do
    echo "### создание временного сертификата $domain ..."
    path="/etc/letsencrypt/live/$domain"
    mkdir -p "$cert_path/conf/live/$domain"
    sudo docker-compose -f ./nginx/docker-compose.yml run --rm --entrypoint "\
      openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
        -keyout "$path/privkey.pem" \
        -out "$path/fullchain.pem" \
        -subj '/CN=localhost'" certbot
    echo
  done

  echo "### Запуск nginx ..."
  sudo docker-compose -f ./nginx/docker-compose.yml up --force-recreate -d
  echo

  # удаление временных сертификатов
  for domain in "${domains[@]}"; do
    echo "### удаление временного сертификата $domain ..."
    sudo docker-compose -f ./nginx/docker-compose.yml run --rm --entrypoint "\
      rm -Rf /etc/letsencrypt/live/$domain" certbot
    echo
  done

  echo "### Запрос сертификатов Let's Encrypt ..."  

  # установка параметра email для certbot
  case "$email" in
    "") email_arg="--register-unsafely-without-email" ;;
    *) email_arg="--email $email" ;;
  esac

  # запрос сертификатов
  for domain in "${domains[@]}"; do
    sudo docker-compose -f ./nginx/docker-compose.yml run --rm --entrypoint "\
      certbot certonly --webroot -w /var/www/certbot \
        $staging_arg \
        $email_arg \
        -d $domain \
        --rsa-key-size $rsa_key_size \
        --agree-tos \
        --force-renewal" certbot
    echo
  done

  echo "### перезапуск Nginx ..."
  sudo docker-compose -f ./nginx/docker-compose.yml exec proxy nginx -s reload

else
  echo "### Запуск nginx ..."
  sudo docker-compose -f ./nginx/docker-compose.yml up --force-recreate -d
  echo
fi


