# pymongo-api

## Как запустить

Запускаем mongodb redis и приложение

```shell
docker compose up -d
```

Заполняем mongodb данными

```shell
 windows
wsl . ./mongo-init-repl-cache.sh
 linux 
. ./mongo-init-repl-cache.sh
```

## Как проверить
```shell
windows
wsl . ./testScript.sh
linux
. ./testScript.sh
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