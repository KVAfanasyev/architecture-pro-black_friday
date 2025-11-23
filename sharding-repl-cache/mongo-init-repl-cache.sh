#!/bin/bash

###
# Инициализируем бд
###

echo "Waiting for MongoDB services to start..."
sleep 45

# Ждем готовности каждого конфиг сервера
echo "Waiting for config servers to be ready..."
until docker exec mongodb-config1 mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 5
done
until docker exec mongodb-config2 mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 5
done
until docker exec mongodb-config3 mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 5
done

# Подключение и инициализация replica set для config server (3 узла)
echo "Initializing config replica set..."
docker exec -it mongodb-config1 mongosh --eval '
rs.initiate({
  _id: "configrs",
  configsvr: true,
  members: [
    { _id: 0, host: "mongodb-config1:27017" },
    { _id: 1, host: "mongodb-config2:27017" },
    { _id: 2, host: "mongodb-config3:27017" }
  ]
})'

echo "Waiting for config replica set to initialize..."
sleep 15

# Проверка статуса config server
echo "Checking config replica set status..."
docker exec -it mongodb-config1 mongosh --eval 'rs.status()'

# Ждем готовности шардов
echo "Waiting for shard servers to be ready..."
until docker exec mongodb-shard1-primary mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 5
done

# Инициализация replica set для первого шарда (Primary + 2 Secondary)
echo "Initializing shard1 replica set..."
docker exec -it mongodb-shard1-primary mongosh --eval '
rs.initiate({
  _id: "shard1rs",
  members: [
    { _id: 0, host: "mongodb-shard1-primary:27017", priority: 2 },
    { _id: 1, host: "mongodb-shard1-secondary1:27017", priority: 1 },
    { _id: 2, host: "mongodb-shard1-secondary2:27017", priority: 1 }
  ]
})'

echo "Waiting for shard1 replica set to initialize..."
sleep 15

# Проверка статуса shard1
echo "Checking shard1 replica set status..."
docker exec -it mongodb-shard1-primary mongosh --eval 'rs.status()'

# Инициализация replica set для второго шарда (Primary + 2 Secondary)
echo "Initializing shard2 replica set..."
docker exec -it mongodb-shard2-primary mongosh --eval '
rs.initiate({
  _id: "shard2rs",
  members: [
    { _id: 0, host: "mongodb-shard2-primary:27017", priority: 2 },
    { _id: 1, host: "mongodb-shard2-secondary1:27017", priority: 1 },
    { _id: 2, host: "mongodb-shard2-secondary2:27017", priority: 1 }
  ]
})'

echo "Waiting for shard2 replica set to initialize..."
sleep 15

# Проверка статуса shard2
echo "Checking shard2 replica set status..."
docker exec -it mongodb-shard2-primary mongosh --eval 'rs.status()'

# Ждем готовности роутера
echo "Waiting for mongos router to be ready..."
until docker exec mongodb-router mongosh --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
    sleep 5
done

# Подключение к mongos роутеру и добавление шардов
echo "Adding shards to cluster..."
docker exec -it mongodb-router mongosh --eval '

// Добавление первого шарда
sh.addShard("shard1rs/mongodb-shard1-primary:27017,mongodb-shard1-secondary1:27017,mongodb-shard1-secondary2:27017")

// Добавление второго шарда
sh.addShard("shard2rs/mongodb-shard2-primary:27017,mongodb-shard2-secondary1:27017,mongodb-shard2-secondary2:27017")

// Проверка добавленных шардов
sh.status()'

# Активация шардирования для целевой базы данных
echo "Enabling sharding for database..."
docker exec -it mongodb-router mongosh --eval '
sh.enableSharding("somedb")'

# Проверка включенного шардирования
docker exec -it mongodb-router mongosh --eval '
sh.status()'

# Создание коллекции с валидацией схемы для UserModel
echo "Creating collections with schema validation..."
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

# Шардирование коллекции users с хэш-распределением по _id
echo "Sharding users collection..."
docker exec -it mongodb-router mongosh --eval '
sh.shardCollection("somedb.users", { "_id": "hashed" })'

# Создание коллекции helloDoc и шардирование по полю name
echo "Creating and sharding helloDoc collection..."
docker exec -it mongodb-router mongosh somedb --eval '
// Создаем коллекцию helloDoc без валидатора схемы
db.createCollection("helloDoc")

// Шардируем коллекцию helloDoc по полю name
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })'

# Создание индексов для оптимизации запросов
echo "Creating indexes for query optimization..."
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

# Настройка read preferences для репликации
echo "Configuring read preferences..."
docker exec -it mongodb-router mongosh --eval '
// Настройка read preference для использования secondary узлов
db.adminCommand({
  setDefaultRWConcern: 1,
  defaultReadConcern: { level: "local" },
  defaultWriteConcern: { w: "majority" }
})'

# Вставка тестовых данных
echo "Inserting test data..."
docker exec -it mongodb-router mongosh somedb --eval '
// Вставляем тестовые данные в helloDoc
for(var i = 0; i < 2000; i++) {
    db.helloDoc.insertOne({age: i, name: "ly" + i})
}

// Вставляем тестовые данные в users
for(var i = 0; i < 2000; i++) {
    db.users.insertOne({age: Math.floor(Math.random() * 100), name: "user" + i})
}'

# Полная проверка статуса кластера
echo "Running final cluster status check..."
docker exec -it mongodb-router mongosh --eval '
sh.status()

// Проверка конкретно коллекций
db = db.getSiblingDB("somedb")
print("Users collection info:")
db.users.getShardDistribution()

print("HelloDoc collection info:")
db.helloDoc.getShardDistribution()

// Дополнительные проверки репликационных наборов
db.adminCommand({ listShards: 1 })
db.adminCommand({ isMaster: 1 })

// Проверка репликационных наборов шардов
sh.status(true)'

# Проверка Redis
echo "Checking Redis connection..."
docker exec redis-cache redis-cli ping

echo "MongoDB sharding cluster with replication and Redis cache initialized successfully!"
echo "API is available at: http://localhost:8080"
echo "Redis cache is available at: localhost:6379"