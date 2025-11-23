# Архитектурный документ: Использование Cassandra для критически важных данных "Мобильного мира"
## 1. Анализ критически важных данных
### 1.1 Критически важные сущности и их требования
#### Корзины покупок (carts):

* **Критичность:** Высокая

* **Требования:** Низкая latency записи/чтения, высокая доступность, геораспределённость

* **Обоснование:** Потеря корзин приводит к прямым потерям продаж

#### Инвентарь (inventory):

* **Критичность:** Высокая

* **Требования:** Консистентность, высокая скорость обновления, геораспределённость

* **Обоснование:** Конфликтующие обновления остатков могут привести к overselling

#### Заказы (orders):

* **Критичность:** Средняя-высокая

* **Требования:** Гарантированная запись, консистентность чтения

* **Обоснование:** Потеря заказов неприемлема, но допускается некоторая задержка репликации

#### Пользовательские сессии:

* **Критичность:** Средняя

* **Требования:** Низкая latency, высокая доступность

* **Обоснование:** Влияет на пользовательский опыт, но данные могут быть восстановлены

## 2. Концептуальная модель для Cassandra
### 2.1 Таблица корзин (carts)

```cql
CREATE TABLE mobile_world.carts (
    session_id uuid,
    user_id uuid,
    geo_zone text,
    cart_status text,
    items list<frozen<cart_item>>,
    created_at timestamp,
    updated_at timestamp,
    expires_at timestamp,
    PRIMARY KEY ((session_id), user_id, geo_zone)
) WITH default_time_to_live = 2592000; -- 30 дней TTL
```
Тип cart_item:
```cql
CREATE TYPE mobile_world.cart_item (
    product_id uuid,
    quantity int,
    added_at timestamp
);
```

**Partition Key:** session_id
**Clustering Keys:** user_id, geo_zone

#### Обоснование:

* session_id обеспечивает равномерное распределение по кластеру

* Быстрый доступ к корзине по сессии

* Поддержка слияния корзин при авторизации через user_id

### 2.2 Таблица инвентаря (inventory)
```cql
CREATE TABLE mobile_world.inventory (
    product_id uuid,
    geo_zone text,
    quantity counter,
    reserved counter,
    last_updated timestamp,
    PRIMARY KEY ((product_id, geo_zone))
);
```
**Partition Key:** product_id, geo_zone

**Обоснование:**

* Локализация остатков по товару и геозоне

* Избегание "горячих партиций" через комбинированный ключ

* Использование counter типа для атомарных обновлений
  
### 2.3 Таблица заказов (orders)
```cql
CREATE TABLE mobile_world.orders (
    order_id uuid,
    user_id uuid,
    geo_zone text,
    order_date timestamp,
    order_status text,
    total_amount decimal,
    items list<frozen<order_item>>,
    created_at timestamp,
    PRIMARY KEY ((order_id), user_id, order_date)
) WITH CLUSTERING ORDER BY (user_id ASC, order_date DESC);
```
#### Тип order_item:
```cql
CREATE TYPE mobile_world.order_item (
    product_id uuid,
    product_name text,
    quantity int,
    price decimal,
    category text
);
```

**Partition Key:** order_id
**Clustering Keys:** user_id, order_date

**Обоснование:**

* order_id обеспечивает равномерное распределение

* Эффективные запросы истории заказов пользователя

* Сортировка по дате для быстрого доступа к последним заказам
  
### 2.4 Таблица пользовательских сессий (user_sessions)
```cql
CREATE TABLE mobile_world.user_sessions (
    user_id uuid,
    session_id uuid,
    session_data text,
    last_activity timestamp,
    geo_zone text,
    PRIMARY KEY ((user_id), session_id)
) WITH default_time_to_live = 86400; -- 24 часа TTL
```

**Partition Key:** user_id

**Clustering Key:** session_id

## 3. Стратегии обеспечения целостности данных
###   3.1 Выбор стратегий по сущностям
####  Корзины (carts):

* Hinted Handoff: Включен

* Read Repair: Вероятность 0.1

* Anti-Entropy Repair: Еженедельно

* Уровень консистентности: QUORUM для записи, ONE для чтения

* Обоснование: Баланс между производительностью и консистентностью, допускается некоторая рассинхронизация

#### Инвентарь (inventory):

* Hinted Handoff: Включен

* Read Repair: Вероятность 1.0

* Anti-Entropy Repair: Ежедневно

* Уровень консистентности: QUORUM для записи и чтения

* Обоснование: Высокие требования к консистентности, предотвращение overselling

#### Заказы (orders):

* Hinted Handoff: Включен

* Read Repair: Вероятность 0.5

* Anti-Entropy Repair: Еженедельно

* Уровень консистентности: LOCAL_QUORUM для записи, ONE для чтения

* Обоснование: Гарантированная запись с учетом географического распределения

 
## 4. Преимущества выбранной архитектуры
###   4.1 Распределение нагрузки
* Композитные partition keys предотвращают "горячие партиции"

* Географическая локализация через geo_zone в ключах

* Равномерное распределение за счет UUID-based ключей

### 4.2 Устойчивость к решардингу
* Стабильные хэш-функции на основе естественных ключей

* Минимальное перемещение данных при добавлении узлов

* Локализованные обновления через географическое шардирование

### 4.3 Производительность
* Низкая latency для критических операций корзины

* Атомарные обновления инвентаря через counter типа

* Эффективные запросы через оптимизированные первичные ключи

## 5. Заключение
   Выбранная архитектура Cassandra обеспечивает:

* Высокую доступность критических данных корзин и инвентаря

* Геораспределённость с оптимизированной latency

* Масштабируемость без деградации производительности

* Баланс консистентности и производительности через дифференцированные стратегии ремонта

* Миграция указанных сущностей в Cassandra позволит "Мобильному миру" обеспечить надежную работу системы при экстремальных нагрузках и географическом росте.