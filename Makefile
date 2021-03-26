SHELL := /bin/bash

build:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Fetching pbf if not cached and then copying to settings dir"
	@echo "------------------------------------------------------------------"
	@docker-compose build pbf
	@docker-compose up -d pbf
	@docker cp maceiramergindbsync_pbf_1:/settings/country.pbf ../osm_conf
	@docker-compose rm -f pbf

ps:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Current status"
	@echo "------------------------------------------------------------------"
	@docker-compose ps

deploy: build
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Starting all containers"
	@echo "------------------------------------------------------------------"
	@docker-compose up -d

restart:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Restarting all containers"
	@echo "------------------------------------------------------------------"
	@docker-compose restart

db-shell:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Creating db shell"
	@echo "------------------------------------------------------------------"
	@docker-compose exec -u postgres db psql gis

db-qgis-project-backup:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Backing up QGIS project stored in db"
	@echo "------------------------------------------------------------------"
	@docker-compose exec -u postgres db pg_dump -f /tmp/QGISProject.sql -t qgis_projects gis
	@docker cp maceiramergindbsync_db_1:/tmp/QGISProject.sql .
	@docker-compose exec -u postgres db rm /tmp/QGISProject.sql
	@ls -lah QGISProject.sql

db-qgis-project-restore:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Restoring QGIS project to db"
	@echo "------------------------------------------------------------------"
	@docker cp QGISProject.sql maceiramergindbsync_db_1:/tmp/ 
	# - at start of next line means error will be ignored (in case QGIS project table isnt already there)
	-@docker-compose exec -u postgres db psql -c "drop table qgis_projects;" gis 
	@docker-compose exec -u postgres db psql -f /tmp/QGISProject.sql -d gis
	@docker-compose exec db rm /tmp/QGISProject.sql
	@docker-compose exec -u postgres db psql -c "select name from qgis_projects;" gis 

db-backup:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Backing up entire postgres db"
	@echo "------------------------------------------------------------------"
	@docker-compose exec -u postgres db pg_dump -Fc -f /tmp/smallholding-database.dmp gis
	@docker cp maceiramergindbsync_db_1:/tmp/smallholding-database.dmp .
	@docker-compose exec -u postgres db rm /tmp/smallholding-database.dmp
	@ls -lah smallholding-database.dmp

db-backup-mergin-base-schema:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Backing up mergin base schema from  postgres db"
	@echo "------------------------------------------------------------------"
	@docker-compose exec -u postgres db pg_dump -Fc -f /tmp/mergin-base-schema.dmp -n mergin_sync_base_do_not_touch gis
	@docker cp maceiramergindbsync_db_1:/tmp/mergin-base-schema.dmp .
	@docker-compose exec -u postgres db rm /tmp/mergin-base-schema.dmp
	@ls -lah mergin-base-schema.dmp

reinitialise-mapproxy:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Restarting Mapproxy and clearing its cache"
	@echo "------------------------------------------------------------------"
	@docker-compose kill mapproxy
	@docker-compose rm mapproxy
	@rm -rf mapproxy_conf/cache_data/*
	@docker-compose up -d mapproxy
	@docker-compose logs -f mapproxy


reinitialise-qgis-server:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Restarting QGIS Server and Nginx"
	@echo "------------------------------------------------------------------"
	@docker-compose kill qgis-server
	@docker-compose rm qgis-server
	@docker-compose up -d qgis-server
	@docker-compose restart nginx
	@docker-compose logs -f qgis-server 


kill-osm:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Deleting all imported OSM data and killing containers"
	@echo "------------------------------------------------------------------"
	@docker-compose kill imposm
	@docker-compose kill osmupdate
	@docker-compose kill osmenrich
	@docker-compose rm imposm
	@docker-compose rm osmupdate
	@docker-compose rm osmenrich
	# Next commands have - in front as they as non compulsory to succeed
	-@sudo rm osm_conf/timestamp.txt
	-@sudo rm osm_conf/last.state.txt
	-@sudo rm osm_conf/importer.lock
	-@docker-compose exec -u postgres db psql -c "drop schema osm cascade;" gis 
	-@docker-compose exec -u postgres db psql -c "drop schema osm_backup cascade;" gis 
	-@docker-compose exec -u postgres db psql -c "drop schema osm_import cascade;" gis 


reinitialise-osm: kill-osm
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Deleting all imported OSM data and reloading"
	@echo "------------------------------------------------------------------"
	@docker-compose up -d imposm osmupdate osmenrich 
	@docker-compose logs -f imposm osmupdate osmenrich

osm-to-mbtiles:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Creating a vector tiles store from the docker osm schema"
	@echo "------------------------------------------------------------------"
    #@docker-compose run osm-to-mbtiles
	@echo "we use below for now because the container aproach doesnt have a new enough gdal (2.x vs >=3.1 needed)"
	@ogr2ogr -f MBTILES osm.mbtiles PG:"dbname='gis' host='localhost' port='15432' user='docker' password='docker' SCHEMAS=osm" -dsco "MAXZOOM=10 BOUNDS=-7.389126,39.410085,-7.381439,39.415144"
	
redeploy-mergin:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Stopping merging container, rebuilding the image, then restarting mergin db sync"
	@echo "------------------------------------------------------------------"
	-@docker-compose kill mergin-sync
	-@docker-compose rm mergin-sync
	-@docker rmi mergin_db_sync
	@git clone git@github.com:lutraconsulting/mergin-db-sync.git --depth=1
	@cd mergin-db-sync; docker build --no-cache -t mergin_db_sync .; cd ..
	@rm -rf mergin-db-sync
	@docker-compose up -d mergin-sync
	@docker-compose logs -f mergin-sync

reinitialise-mergin:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Deleting mergin database schemas and removing local sync files"
	@echo "Then restarting the mergin sync service"
	@echo "------------------------------------------------------------------"
	@docker-compose kill mergin-sync
	@docker-compose rm mergin-sync
	@sudo rm -rf mergin_sync_data/*
	@docker-compose exec -u postgres db psql -c "drop schema smallholding cascade;" gis 
	@docker-compose exec -u postgres db psql -c "drop schema mergin_sync_base_do_not_touch cascade;" gis 
	@docker-compose up -d mergin-sync
	@docker-compose logs -f mergin-sync


mergin-logs:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Polling mergin-db-sync logs"
	@echo "------------------------------------------------------------------"
	@docker-compose logs -f mergin-sync


qgis-logs:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Polling QGIS Server logs"
	@echo "------------------------------------------------------------------"
	@docker-compose logs -f qgis-server


odm-clean:
	@echo "------------------------------------------------------------------"
	@echo "Note that the odm_datasets directory should be considered mutable as this script "
	@echo "cleans out all other files"
	@echo "------------------------------------------------------------------"
	@sudo rm -rf odm_datasets/smallholding/odm*
	@sudo rm -rf odm_datasets/smallholding/cameras.json
	@sudo rm -rf odm_datasets/smallholding/img_list.txt
	@sudo rm -rf odm_datasets/smallholding/cameras.json
	@sudo rm -rf odm_datasets/smallholding/opensfm
	@sudo rm -rf odm_datasets/smallholding/images.json

odm-run: odm-clean
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Generating ODM Ortho, DEM, DSM then clipping it and loading it into postgis"
	@echo "Before running please remove any old images from odm_datasets/smallholding/images"
	@echo "and copy the images that need to be mosaicked into it."
	@echo "Note that the odm_datasets directory should be considered mutable as this script "
	@echo "cleans out all other files"
	@echo "------------------------------------------------------------------"
	@docker-compose run odm

odm-clip:
	@echo "------------------------------------------------------------------"
	@echo "Clippint Ortho, DEM, DSM"
	@echo "------------------------------------------------------------------"
	@docker-compose run odm-ortho-clip
	@docker-compose run odm-dsm-clip
	@docker-compose run odm-dtm-clip

odm-pgraster: export PGPASSWORD = docker
odm-pgraster:
	@echo "------------------------------------------------------------------"
	@echo "Loading ODM products into postgis"
	@echo "------------------------------------------------------------------"
	# Todo - run in docker rather than localhost, currently requires pgraster installed locally
	-@echo "drop schema raster cascade;" | psql -h localhost -p 15432 -U docker gis
	@echo "create schema raster;" | psql -h localhost -p 15432 -U docker gis
	@raster2pgsql -s 32629 -t 256x256 -C -l 4,8,16,32,64,128,256,512 -P -F -I ./odm_datasets/orthophoto.tif raster.orthophoto | psql -h localhost -p 15432 -U docker gis
	@raster2pgsql -s 32629 -t 256x256 -C -l 4,8,16,32,64,128,256,512 -d -P -F -I ./odm_datasets/dtm.tif raster.dtm | psql -h localhost -p 15432 -U docker gis
	@raster2pgsql -s 32629 -t 256x256 -C -l 4,8,16,32,64,128,256,512 -d -P -F -I ./odm_datasets/dsm.tif raster.dsm | psql -h localhost -p 15432 -U docker gis

# Runs above 3 tasks all in one go
odm: odm-run odm-clip odm-pgraster



kill:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Killing all containers"
	@echo "------------------------------------------------------------------"
	@docker-compose kill

rm: kill
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Removing all containers"
	@echo "------------------------------------------------------------------"
	@docker-compose rm

nuke:
	@echo
	@echo "------------------------------------------------------------------"
	@echo "Nuking Everything!
	@echo "------------------------------------------------------------------"
	@sudo rm -rf postgis_data/*
	@sudo rm -rf mergin_sync_data/*
	@sudo rm -rf geoserver_data/*
	@sudo rm -rf certbot/certbot

