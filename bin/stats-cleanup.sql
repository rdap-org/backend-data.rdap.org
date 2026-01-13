DELETE FROM `queries_by_status` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
DELETE FROM `queries_by_type` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
DELETE FROM `queries_by_user_agent` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
DELETE FROM `queries_by_network` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
DELETE FROM `queries_by_tld` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
DELETE FROM `queries_by_origin` WHERE (`timestamp` < UNIXEPOCH()-(86400*30));
VACUUM;
