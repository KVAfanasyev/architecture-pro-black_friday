# Стратегия управления горячими шардами в MongoDB
## 1. Метрики мониторинга для выявления горячих шардов
###   1.1 Основные метрики производительности
```yaml
# Метрики для мониторинга в реальном времени
shard_metrics:
  cpu_usage:
    description: "Загрузка CPU по шардам"
    threshold: 80% # порог предупреждения
    critical_threshold: 90% # порог критического состояния
  
  memory_usage:
    description: "Использование оперативной памяти"
    threshold: 85%
  
  disk_io:
    description: "Операции ввода-вывода на диск"
    metrics: [read_iops, write_iops, disk_utilization]
  
  network_io:
    description: "Сетевая активность"
    metrics: [bytes_in, bytes_out]
```
### 1.2 Метрики распределения данных и нагрузки
```yaml
# Метрики для мониторинга в реальном времени
shard_metrics:
  cpu_usage:
    description: "Загрузка CPU по шардам"
    threshold: 80% # порог предупреждения
    critical_threshold: 90% # порог критического состояния
  
  memory_usage:
    description: "Использование оперативной памяти"
    threshold: 85%
  
  disk_io:
    description: "Операции ввода-вывода на диск"
    metrics: [read_iops, write_iops, disk_utilization]
  
  network_io:
    description: "Сетевая активность"
    metrics: [bytes_in, bytes_out]
```
### 1.2 Метрики распределения данных и нагрузки
```yaml
distribution_metrics:
  chunk_distribution:
    description: "Распределение чанков по шардам"
    alert_condition: "разница > 30% между максимальным и минимальным количеством чанков"
  
  request_distribution:
    description: "Распределение операций чтения/записи"
    metrics: [reads_per_second, writes_per_second, queries_per_second]
    threshold: "2:1 разница между самым загруженным и наименее загруженным шардом"
  
  data_size_distribution:
    description: "Распределение объема данных"
    threshold: "разница > 40% в размере данных между шардами"
```

### 1.3 Категорийные метрики для товаров
```yaml
category_metrics:
  hot_categories:
    description: "Популярные категории создающие нагрузку"
    calculation: "топ-5 категорий по количеству запросов"
    threshold: "> 25% от общего числа запросов на одну категорию"

  query_patterns:
    description: "Анализ паттернов запросов"
    metrics: [most_frequent_queries, slow_queries, collection_scans]
```

## 2. Механизмы автоматического перераспределения данных
### 2.1 Динамическое перешардирование для горячих категорий
```javascript
// Алгоритм автоматического перераспределения для коллекции products
function redistributeHotCategories() {
  // Мониторинг нагрузки по категориям
  const categoryStats = db.products.aggregate([
    {
      $group: {
        _id: "$category",
        requestCount: { $sum: 1 },
        avgResponseTime: { $avg: "$response_time" },
        shard: { $first: "$shard_id" }
      }
    },
    { $sort: { requestCount: -1 } }
  ]);
  
  // Выявление горячих категорий
  const hotCategories = categoryStats.filter(cat => 
    cat.requestCount > GLOBAL_AVG_REQUEST_COUNT * 1.5
  );
  
  // Перераспределение горячих категорий
  hotCategories.forEach(category => {
    splitAndRedistributeCategory(category._id);
  });
}

function splitAndRedistributeCategory(categoryName) {
  // Разделение категории на подкатегории по атрибутам
  const subCategories = db.products.aggregate([
    { $match: { category: categoryName } },
    {
      $bucket: {
        groupBy: "$attributes.brand", // или другой релевантный атрибут
        boundaries: ["A-F", "G-M", "N-S", "T-Z"],
        output: {
          count: { $sum: 1 },
          products: { $push: "$_id" }
        }
      }
    }
  ]);
  
  // Перераспределение подкатегорий по разным шардам
  subCategories.forEach((subCat, index) => {
    const targetShard = getLeastLoadedShard();
    moveChunkToShard(subCat.products, targetShard);
  });
}
```