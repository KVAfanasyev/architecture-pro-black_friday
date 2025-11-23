import json
import logging
import os
import time
from typing import List, Optional

import motor.motor_asyncio
from bson import ObjectId
from fastapi import Body, FastAPI, HTTPException, status
from fastapi_cache import FastAPICache
from fastapi_cache.backends.redis import RedisBackend
from fastapi_cache.decorator import cache
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from pydantic.functional_validators import BeforeValidator
from pymongo import errors
from redis import asyncio as aioredis
from typing_extensions import Annotated

# Configure JSON logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler()]
)

logger = logging.getLogger(__name__)

app = FastAPI()

# Убираем проблемное middleware или добавляем обработку ошибок
try:
    from logmiddleware import RouterLoggingMiddleware
    app.add_middleware(
        RouterLoggingMiddleware,
        logger=logger,
    )
except Exception as e:
    logger.warning(f"Failed to initialize RouterLoggingMiddleware: {e}")

DATABASE_URL = os.environ["MONGODB_URL"]
DATABASE_NAME = os.environ["MONGODB_DATABASE_NAME"]
REDIS_URL = os.getenv("REDIS_URL", None)


def nocache(*args, **kwargs):
    def decorator(func):
        return func

    return decorator


if REDIS_URL:
    cache = cache
else:
    cache = nocache


client = motor.motor_asyncio.AsyncIOMotorClient(DATABASE_URL)
db = client[DATABASE_NAME]

# Represents an ObjectId field in the database.
# It will be represented as a `str` on the model so that it can be serialized to JSON.
PyObjectId = Annotated[str, BeforeValidator(str)]


@app.on_event("startup")
async def startup():
    if REDIS_URL:
        redis = aioredis.from_url(REDIS_URL, encoding="utf8", decode_responses=True)
        FastAPICache.init(RedisBackend(redis), prefix="api:cache")


class UserModel(BaseModel):
    """
    Container for a single user record.
    """

    id: Optional[PyObjectId] = Field(alias="_id", default=None)
    age: int = Field(...)
    name: str = Field(...)


class UserCollection(BaseModel):
    """
    A container holding a list of `UserModel` instances.
    """

    users: List[UserModel]


async def get_collection_shard_distribution(collection_name: str):
    """
    Получает распределение документов коллекции по шардам для старых версий MongoDB
    """
    try:
        collection = db.get_collection(collection_name)
        total_docs = await collection.count_documents({})

        distribution = {
            "total_documents": total_docs,
            "total_size": 0,
            "sharded": client.is_mongos,
            "shards": {}
        }

        if distribution["sharded"] and total_docs > 0:
            await _get_sharded_distribution_legacy(collection_name, distribution, total_docs)
        elif total_docs > 0:
            await _get_non_sharded_distribution(collection_name, distribution, total_docs)

        return distribution

    except Exception as e:
        logger.error(f"Error in shard distribution for {collection_name}: {str(e)}")
        return {
            "total_documents": total_docs if 'total_docs' in locals() else 0,
            "total_size": 0,
            "sharded": False,
            "shards": {},
            "error": str(e)
        }

async def _get_sharded_distribution_legacy(collection_name: str, distribution: dict, total_docs: int):
    """
    Метод для получения распределения по шардам в старых версиях MongoDB
    """
    try:
        # Получаем информацию о шардах
        shards_list = await client.admin.command("listShards")

        for shard_info in shards_list.get("shards", []):
            shard_name = shard_info["_id"]
            shard_host = shard_info["host"]

            try:
                # Метод 1: Пробуем использовать dbStats для базы данных на каждом шарде
                shard_count = 0
                shard_size = 0

                # Метод 2: Используем агрегацию с $shardCollection (если коллекция шардирована)
                try:
                    # Получаем информацию о шардировании коллекции
                    coll_stats = await db.command("collStats", collection_name)
                    shards_info = coll_stats.get('shards', {})
                    #logger.info(f"shards_info: {shards_info}")
                    if shard_name in shards_info:
                        shard_stats = shards_info[shard_name]
                        shard_count = shard_stats.get('count', 0)
                        shard_size = shard_stats.get('size', 0)
                    else:
                        # Если нет информации в collStats, используем приблизительный расчет
                        shard_count = total_docs // len(shards_list["shards"])

                except Exception as coll_stats_error:
                    logger.warning(f"collStats failed for {shard_name}: {str(coll_stats_error)}")
                    # Приблизительное равномерное распределение
                    shard_count = total_docs // len(shards_list["shards"])

                distribution["shards"][shard_name] = {
                    "documents": shard_count,
                    "size": shard_size,
                    "percentage": round((shard_count / total_docs * 100), 2) if total_docs > 0 else 0,
                    "host": shard_host,
                    "note": "Approximate count (legacy MongoDB version)"
                }

                distribution["total_size"] += shard_size

            except Exception as shard_error:
                logger.warning(f"Error processing shard {shard_name}: {str(shard_error)}")
                distribution["shards"][shard_name] = {
                    "documents": 0,
                    "size": 0,
                    "percentage": 0,
                    "host": shard_host,
                    "error": str(shard_error)
                }

    except Exception as legacy_error:
        logger.error(f"Legacy shard distribution method failed: {str(legacy_error)}")
        distribution["error"] = f"Legacy shard distribution method failed: {str(legacy_error)}"

async def _get_non_sharded_distribution(collection_name: str, distribution: dict, total_docs: int):
    """
    Обработка нешардированных коллекций
    """
    try:
        coll_stats = await db.command("collStats", collection_name)
        collection_size = coll_stats.get('size', 0)
    except Exception as e:
        logger.warning(f"Could not get collection stats: {str(e)}")
        collection_size = 0

    distribution["shards"]["primary"] = {
        "documents": total_docs,
        "size": collection_size,
        "percentage": 100
    }
    distribution["total_size"] = collection_size


async def get_replica_counts():
    """
    Получает количество реплик для каждого шарда и конфиг серверов
    """
    replica_counts = {
        "config_servers": 0,
        "shards": {},
        "total_replica_nodes": 0
    }

    try:
        # Получаем информацию о шардах
        shards_list = await client.admin.command("listShards")

        for shard_info in shards_list.get("shards", []):
            shard_name = shard_info["_id"]
            shard_host = shard_info["host"]

            # Подсчитываем количество узлов в репликасете шарда
            # Формат host: "shard1rs/mongodb-shard1-primary:27017,mongodb-shard1-secondary1:27017,mongodb-shard1-secondary2:27017"
            if '/' in shard_host:
                replica_set_name, hosts_str = shard_host.split('/', 1)
                hosts = hosts_str.split(',')
                replica_counts["shards"][shard_name] = {
                    "replica_set": replica_set_name,
                    "node_count": len(hosts),
                    "hosts": hosts
                }
                replica_counts["total_replica_nodes"] += len(hosts)
            else:
                replica_counts["shards"][shard_name] = {
                    "replica_set": "unknown",
                    "node_count": 1,
                    "hosts": [shard_host]
                }
                replica_counts["total_replica_nodes"] += 1

        # Получаем информацию о конфиг серверах
        try:
            config_db = client.get_database("config")
            config_shards = await config_db.shards.find().to_list(None)

            # Ищем конфиг серверы
            config_replica_count = 0
            for shard in config_shards:
                if shard["_id"].startswith("config"):
                    host = shard["host"]
                    if '/' in host:
                        _, hosts_str = host.split('/', 1)
                        hosts = hosts_str.split(',')
                        config_replica_count = len(hosts)
                    break

            replica_counts["config_servers"] = config_replica_count
            replica_counts["total_replica_nodes"] += config_replica_count

        except Exception as config_error:
            logger.warning(f"Could not get config servers info: {str(config_error)}")
            # Предполагаем стандартную конфигурацию с 3 конфиг серверами
            replica_counts["config_servers"] = 3
            replica_counts["total_replica_nodes"] += 3

    except Exception as e:
        logger.error(f"Error getting replica counts: {str(e)}")
        replica_counts["error"] = str(e)

    return replica_counts


@app.get("/")
async def root():
    collection_names = await db.list_collection_names()
    collections = {}

    # Получаем распределение по шардам для каждой коллекции
    for collection_name in collection_names:
        collection = db.get_collection(collection_name)
        documents_count = await collection.count_documents({})

        # Получаем распределение по шардам
        shard_distribution = await get_collection_shard_distribution(collection_name)

        collections[collection_name] = {
            "documents_count": documents_count,
            "shard_distribution": shard_distribution
        }

    try:
        replica_status = await client.admin.command("replSetGetStatus")
        replica_status = json.dumps(replica_status, indent=2, default=str)
    except errors.OperationFailure:
        replica_status = "No Replicas"

    topology_description = client.topology_description
    read_preference = client.client_options.read_preference
    topology_type = topology_description.topology_type_name
    replicaset_name = topology_description.replica_set_name

    shards = None
    if topology_type == "Sharded":
        shards_list = await client.admin.command("listShards")
        shards = {}
        for shard in shards_list.get("shards", []):
            shards[shard["_id"]] = shard["host"]

    # Получаем информацию о количестве реплик
    replica_counts = await get_replica_counts()

    cache_enabled = False
    if REDIS_URL:
        cache_enabled = FastAPICache.get_enable()

    return {
        "mongo_topology_type": topology_type,
        "mongo_replicaset_name": replicaset_name,
        "mongo_db": DATABASE_NAME,
        "read_preference": str(read_preference),
        "mongo_nodes": client.nodes,
        "mongo_primary_host": client.primary,
        "mongo_secondary_hosts": client.secondaries,
        "mongo_is_primary": client.is_primary,
        "mongo_is_mongos": client.is_mongos,
        "collections": collections,
        "shards": shards,
        "replica_info": replica_counts,  # Добавлена информация о количестве реплик
        "cache_enabled": cache_enabled,
        "status": "OK",
    }


@app.get("/{collection_name}/count")
async def collection_count(collection_name: str):
    collection = db.get_collection(collection_name)
    items_count = await collection.count_documents({})
    return {"status": "OK", "mongo_db": DATABASE_NAME, "items_count": items_count}


@app.get(
    "/{collection_name}/users",
    response_description="List all users",
    response_model=UserCollection,
    response_model_by_alias=False,
)
@cache(expire=60 * 1)
async def list_users(collection_name: str):
    """
    List all of the user data in the database.
    The response is unpaginated and limited to 1000 results.
    """
    time.sleep(1)
    collection = db.get_collection(collection_name)
    return UserCollection(users=await collection.find().to_list(1000))


@app.get(
    "/{collection_name}/users/{name}",
    response_description="Get a single user",
    response_model=UserModel,
    response_model_by_alias=False,
)
async def show_user(collection_name: str, name: str):
    """
    Get the record for a specific user, looked up by `name`.
    """

    collection = db.get_collection(collection_name)
    if (user := await collection.find_one({"name": name})) is not None:
        return user

    raise HTTPException(status_code=404, detail=f"User {name} not found")


@app.post(
    "/{collection_name}/users",
    response_description="Add new user",
    response_model=UserModel,
    status_code=status.HTTP_201_CREATED,
    response_model_by_alias=False,
)
async def create_user(collection_name: str, user: UserModel = Body(...)):
    """
    Insert a new user record.

    A unique `id` will be created and provided in the response.
    """
    collection = db.get_collection(collection_name)
    new_user = await collection.insert_one(
        user.model_dump(by_alias=True, exclude=["id"])
    )
    created_user = await collection.find_one({"_id": new_user.inserted_id})
    return created_user