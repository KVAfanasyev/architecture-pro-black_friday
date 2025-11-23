# pymongo-api

## Как запустить

Запускаем mongodb redis и приложение

```shell
docker compose up -d
```

Заполняем mongodb данными

```shell
 windows
wsl . ./mongo-init-sharding.sh
 linux 
. ./mongo-init-sharding.sh
```

### Если вы запускаете проект на локальной машине

Откройте в браузере http://localhost:8080

### Если вы запускаете проект на предоставленной виртуальной машине

Узнать белый ip виртуальной машины

```shell
curl --silent http://ifconfig.me
```

Откройте в браузере http://<ip виртуальной машины>:8080

## Доступные эндпоинты

Список доступных эндпоинтов, swagger http://<ip виртуальной машины>:8080/docs