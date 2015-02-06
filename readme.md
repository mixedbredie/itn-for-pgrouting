Building ITN for pgRouting
==========================

This document and repository explains how to load Ordnance Survey ITN GML into a PostGIS database with Loader and then build a network suitable for use with pgRouting.  The network will have one way streets, no entry and no turn restrictions, mandatory turns and grade separations for over- and underpasses.  Network costs will be calulated using average travel speeds.  Further realism can be added to the network using more of the road routing information supplied with ITN.  I'll leave that to better brains than mine.

Setting up PostGIS
------------------
I am running this on PostgreSQL 9.3.5 with PostGIS 2.1.5 and pgRouting 2.0.0 on "localhost" with user "postgres".  Adjust your settings as necessary.  This is what I used.

Create a new database: **routing**

Create a new schema: **osmm_itn**

Adjust the search_path variable for user postgres if required to access the osmm_itn schema.

Enable the pgRouting extension: **CREATE EXTENSION pgrouting;**

Configuring Loader
------------------
Get Loader: https://github.com/AstunTechnology/Loader and download and unpack into your working directory.  Follow the instructions to configure Loader to load the ITN GML into PostGIS.

My Loader configuration (sans comments)

    src_dir=C:\Workspace\Loader\ITN_6348787\01
    out_dir=C:\Workspace\Loader\output
    tmp_dir=C:\Workspace\Loader
    ogr_cmd=ogr2ogr --config GML_EXPOSE_FID NO -append -skipfailures -f PostgreSQL PG:'dbname=routing active_schema=osmm_itn host=localhost user=postgres password=yourpassword port=5432' $file_path
    prep_cmd=python prepgml4ogr.py $file_path prep_osgml.prep_osmm_itn
    post_cmd=
    gfs_file=../gfs/osmm_itn_postgres.gfs
    debug=False

Loading
-------
Load the ITN GML into PostGIS using Loader by running in the Loader directory:

    python loader.py loader.config

Note: I used non-geographically chunked GML (as opposed to geographically chunked) from Ordnance Survey - this does not contain duplicate features which can lead to issues later on.

Once the GML has been loaded into PostGIS run the views.sql file in the extras directory of the Loader installation.  This creates a number of views that link the ITN tables together and provide the links between the road links and the road route information (RRI).

Now you should have some tables and some views in the osmm_itn schema in your routing database.

To build a valid network that pgRouting can use you need to create some additional views which contain the information required to model one way streets, grade separations and turn restrictions and mandatory turns.

Update road names and road numbers
----------------------------------

Create one way view
-------------------
![One Way](images/652.jpg)

Create grade separation view
----------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/530A.JPG" alt="Grade Separation" width="206px">

Create network build function
-----------------------------

Create network table
--------------------

Update one way field
--------------------

Update grade separation fields
------------------------------

Rebuild elevated sections
-------------------------

Populate pgRouting fields
-------------------------

Calculate network costs
-----------------------

Create no entry restrictions
----------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/616.jpg" alt="No Entry" width="206px">

Create no turn restrictions
---------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/613.jpg" alt="No Turn" width="206px">

Create mandatory turn restrictions
----------------------------------
![Mandatory Turn](images/609A.jpg)

Build pgRouting topology
------------------------

Analyse network topology
------------------------

pgRouting and QGIS
------------------

References
----------
http://www.ordnancesurvey.co.uk/business-and-government/products/itn-layer.html

https://github.com/AstunTechnology/Loader

http://pgrouting.org/

http://www.archaeogeek.com/blog/2012/08/17/pgrouting-with-ordnance-survey-itn-data/

http://anitagraser.com/?s=pgrouting
