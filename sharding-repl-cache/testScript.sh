#!/bin/bash

echo "=== Testing /users/users endpoint with timing ==="
echo

# Первый запрос (без кэша)
echo "1. First request (uncached):"
start_time=$(date +%s%3N)
curl -s -X GET "http://localhost:8080/users/users" > /dev/null
end_time=$(date +%s%3N)
echo "Time: $((end_time - start_time)) ms"
echo

# Второй запрос (из кэша)
echo "2. Second request (cached):"
start_time=$(date +%s%3N)
curl -s -X GET "http://localhost:8080/users/users" > /dev/null
end_time=$(date +%s%3N)
echo "Time: $((end_time - start_time)) ms"
echo

# Третий запрос (из кэша)
echo "3. Third request (cached):"
start_time=$(date +%s%3N)
curl -s -X GET "http://localhost:8080/users/users" > /dev/null
end_time=$(date +%s%3N)
echo "Time: $((end_time - start_time)) ms"