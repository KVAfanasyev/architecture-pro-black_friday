#!/bin/bash

###
# Инициализируем бд
###

# Подключение и инициализация replica set для config server
docker exec -it mongodb-config mongosh --eval '
rs.initiate({
  _id: "configrs",
  configsvr: true,
  members: [
    { _id: 0, host: "mongodb-config:27017" }
  ]
})'

# Проверка статуса config server
docker exec -it mongodb-config mongosh --eval 'rs.status()'


# Инициализация replica set для первого шарда
docker exec -it mongodb-shard1 mongosh --eval '
rs.initiate({
  _id: "shard1rs",
  members: [
    { _id: 0, host: "mongodb-shard1:27017" }
  ]
})'

# Проверка статуса shard1
docker exec -it mongodb-shard1 mongosh --eval 'rs.status()'


# Инициализация replica set для второго шарда
docker exec -it mongodb-shard2 mongosh --eval '
rs.initiate({
  _id: "shard2rs",
  members: [
    { _id: 0, host: "mongodb-shard2:27017" }
  ]
})'

# Проверка статуса shard2
docker exec -it mongodb-shard2 mongosh --eval 'rs.status()'




# Подключение к mongos роутеру и добавление шардов
docker exec -it mongodb-router mongosh --eval '

// Добавление первого шарда
sh.addShard("shard1rs/mongodb-shard1:27017")

// Добавление второго шарда  
sh.addShard("shard2rs/mongodb-shard2:27017")

// Проверка добавленных шардов
sh.status()'



# Активация шардирования для целевой базы данных
docker exec -it mongodb-router mongosh --eval '
sh.enableSharding("somedb")'

# Проверка включенного шардирования
docker exec -it mongodb-router mongosh --eval '
sh.status()'


# Создание коллекции с валидацией схемы для UserModel
docker exec -it mongodb-router mongosh somedb --eval '
// Создаем коллекцию users с валидацией схемы
db.createCollection("users", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["age", "name"],
      properties: {
        _id: {
          bsonType: "objectId",
          description: "ObjectId field - required"
        },
        age: {
          bsonType: "int",
          minimum: 0,
          maximum: 150,
          description: "age must be an integer between 0 and 150 and is required"
        },
        name: {
          bsonType: "string",
          minLength: 1,
          maxLength: 100,
          description: "name must be a string between 1 and 100 characters and is required"
        }
      }
    }
  }
})'

# Шардирование коллекции users с хэш-распределением по _id (как в UserModel)
docker exec -it mongodb-router mongosh --eval '
sh.shardCollection("somedb.users", { "_id": "hashed" })'

# Исправленная часть скрипта для создания коллекций
# Создание коллекции helloDoc и шардирование по полю name
docker exec -it mongodb-router mongosh somedb --eval '
// Создаем коллекцию helloDoc без валидатора схемы
db.createCollection("helloDoc")

// Шардируем коллекцию helloDoc по полю name
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })'


# Создание индексов для оптимизации запросов
docker exec -it mongodb-router mongosh somedb --eval '
// Индекс для поиска по имени (часто используется в API)
db.users.createIndex({ "name": 1 })
db.helloDoc.createIndex({ "name": 1 })

// Индекс для поиска по возрасту
db.users.createIndex({ "age": 1 })
db.helloDoc.createIndex({ "age": 1 })

// Комбинированный индекс для запросов по имени и возрасту
db.users.createIndex({ "name": 1, "age": 1 })
db.helloDoc.createIndex({ "name": 1, "age": 1 })'

# Полная проверка статуса кластера
docker exec -it mongodb-router mongosh --eval '
sh.status()

// Проверка конкретно коллекций
db = db.getSiblingDB("somedb")
print("Users collection info:")
db.users.getShardDistribution()

print("HelloDoc collection info:")
db.helloDoc.getShardDistribution()

// Дополнительные проверки
db.adminCommand({ listShards: 1 })
db.adminCommand({ isMaster: 1 })'

# Проверка шардирования коллекций
docker exec -it mongodb-router mongosh somedb --eval '
// Проверяем распределение данных по шардам для users
print("=== Users collection distribution ===")
db.users.getShardDistribution()

// Проверяем распределение данных по шардам для helloDoc
print("=== HelloDoc collection distribution ===")
db.helloDoc.getShardDistribution()

// Проверяем настройки шардирования
print("=== Sharding settings ===")
print("Users sharded:", db.users.stats().sharded)
print("HelloDoc sharded:", db.helloDoc.stats().sharded)

// Проверяем валидацию схемы для users
print("=== Schema validation ===")
db.getCollectionInfos({name: "users"})[0].options.validator'

# Вставка тестовых данных в коллекцию helloDoc
docker exec -it mongodb-router mongosh somedb --eval '
// Вставляем тестовые данные в helloDoc
for(var i = 0; i < 1000; i++) { 
    db.helloDoc.insertOne({age: i, name: "ly" + i})
}

// Проверяем распределение данных после вставки
print("=== Final distribution after data insertion ===")
db.helloDoc.getShardDistribution()'