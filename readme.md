Building ITN for pgRouting
==========================

This document and repository explains how to load Ordnance Survey ITN GML into a PostGIS database with Loader and then build a network suitable for use with pgRouting.  The network will have one way streets, no entry and no turn restrictions, mandatory turns and grade separations for over- and underpasses.  Network costs will be calulated using average travel speeds.  Further realism can be added to the network using more of the road routing information supplied with ITN.  I'll leave that to better brains than mine.

Setting up PostGIS
------------------

Configuring Loader
------------------

Loading
-------

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
