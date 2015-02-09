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
First let's update the roadlink table with road names and road numbers.  Add the roadname and roadnumber fields to the roadlink table:

    ALTER TABLE roadlink ADD COLUMN roadname character varying(250);
    ALTER TABLE roadlink ADD COLUMN roadnumber character varying(70);

This uses the road table to update the roadlink table with road names.  Takes some time to run if you have a large dataset.

    UPDATE roadlink SET roadname = 
    (
    SELECT DISTINCT array_to_string(c.roadname,', ') AS roadname 
    FROM roadlink a 
    INNER JOIN road_roadlink b ON b.roadlink_fid = a.fid
    INNER JOIN road c ON c.fid = b.road_fid
    WHERE a.fid = roadlink.fid 
    AND c.descriptivegroup = 'Named Road'
    );

The following three queries update the roadlink table with the DFT road numbers.  This is somewhat quicker than the query above as there usually fewer records to update.

Update Motorways

    UPDATE roadlink SET dftname = 
    (
    SELECT DISTINCT array_to_string(c.roadname,', ') AS roadname 
    FROM roadlink a 
    INNER JOIN road_roadlink b ON b.roadlink_fid = a.fid
    INNER JOIN road c ON c.fid = b.road_fid
    WHERE a.fid = roadlink.fid 
    AND c.descriptivegroup = 'Motorway'
    )
    WHERE roadlink.descriptiveterm = 'Motorway';

Update A Roads

    UPDATE roadlink SET dftname = 
    (
    SELECT DISTINCT array_to_string(c.roadname,', ') AS roadname 
    FROM roadlink a 
    INNER JOIN road_roadlink b ON b.roadlink_fid = a.fid
    INNER JOIN road c ON c.fid = b.road_fid
    WHERE a.fid = roadlink.fid 
    AND c.descriptivegroup = 'A Road'
    )
    WHERE roadlink.descriptiveterm = 'A Road';

Update B Roads

    UPDATE roadlink SET dftname = 
    (
    SELECT DISTINCT array_to_string(c.roadname,', ') AS roadname 
    FROM roadlink a 
    INNER JOIN road_roadlink b ON b.roadlink_fid = a.fid
    INNER JOIN road c ON c.fid = b.road_fid
    WHERE a.fid = roadlink.fid 
    AND c.descriptivegroup = 'B Road'
    )
    WHERE roadlink.descriptiveterm = 'B Road';

Create one way view
-------------------
![One Way](images/652.jpg)
Start with creating a view of one way streets in the network.  This combines the information in the roadrouteinformation table with the view linking the roadlinks and roadrouteinformation to select out the streets with a "one way" environmental qualifier.  It also adds a numeric value to the roadlink to indicate whether the one way direction is the same as the digitised direction of the link as shown by the "+" and "-".  These values will be used later in the network table.

    -- View: view_itn_oneway
    -- DROP VIEW view_itn_oneway;
    CREATE OR REPLACE VIEW view_itn_oneway AS 
    SELECT replace(array_to_string(rri.directedlink_href, ', '::text), '#'::text, ''::text) AS directedlink_href,
      rrirl.roadrouteinformation_fid,
      array_to_string(rri.directedlink_orientation, ', '::text) AS directedlink_orientation,
      array_to_string(rri.environmentqualifier_instruction, ', '::text) AS environmentqualifier,
        CASE
            WHEN rri.directedlink_orientation::text = '{+}'::text THEN 512
            ELSE 1024
        END AS oneway_attr
    FROM roadrouteinformation_roadlink rrirl
    RIGHT JOIN roadrouteinformation rri ON rri.fid::text = rrirl.roadrouteinformation_fid::text
    WHERE rri.environmentqualifier_instruction = '{"One Way"}'::character varying[];
    ALTER TABLE view_itn_oneway
      OWNER TO postgres;
    COMMENT ON VIEW view_itn_oneway 
      IS 'ITN one way streets view';

Create grade separation view
----------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/530A.JPG" alt="Grade Separation" width="206px">
Then create a view to hold all the links with grade separation values of 1, i.e. elevated at one or both ends.  The view will be used to identify all the links in the final network table that make up bridges and overpasses.

    -- View: view_itn_gradeseparation
    -- DROP VIEW view_itn_gradeseparation;
    CREATE OR REPLACE VIEW view_itn_gradeseparation AS 
      SELECT rl.fid,
      rl.ogc_fid,
      rl.directednode_gradeseparation[1] AS gradeseparation_s,
      rl.directednode_gradeseparation[2] AS gradeseparation_e,
      COALESCE(((rl.roadname::text || ' ('::text) || rl.dftname::text) || ')'::text, COALESCE(rl.dftname::text, rl.descriptiveterm::text)) AS roadname,
      rl.wkb_geometry
    FROM roadlink rl
    WHERE rl.directednode_gradeseparation = '{0,1}'::integer[] OR rl.directednode_gradeseparation = '{1,1}'::integer[] OR rl.directednode_gradeseparation = '{1,0}'::integer[];
    ALTER TABLE view_itn_gradeseparation
      OWNER TO postgres;
    COMMENT ON VIEW view_itn_gradeseparation
      IS 'ITN links with grade separation';

This is a work in progress here but pgRouting has some issues with bridges being split where they cross the underlying road link.  So, in an attempt to build a better network the following view takes the road links with grade separation values of 1 and unions then merges the input to create single linestrings representing the bridge.  These are then put back into the final network table replacing the existing road links.

    -- View: view_itn_bridges

    -- DROP VIEW view_itn_bridges;

    CREATE OR REPLACE VIEW view_itn_bridges AS 
     SELECT gs.roadname,
        (st_dump(st_linemerge(st_union(gs.wkb_geometry)))).geom AS wkb_geometry
     FROM view_itn_gradeseparation gs
     GROUP BY gs.roadname;

    ALTER TABLE view_itn_bridges
      OWNER TO postgres;

Create network table
--------------------
Once we have this in place we can create an empty table to hold the route network geometry and attributes required for pgRouting.  I am going to call my table "itn_network".

    -- Table: itn_network
    
    -- DROP TABLE itn_network;
    
    CREATE TABLE itn_network
    (
      fkey_pkey integer,
      gradeseparation_s integer,
      gradeseparation_e integer,
      oneway integer,
      toid character varying(30),
      dftname character varying(200),
      roadname character varying(200),
      length double precision,
      natureofroad character varying(40),
      geometry geometry,
      descriptivegroup character varying(20),
      descriptiveterm character varying(40),
      rl_attribute integer,
      rl_speed integer,
      rl_width integer,
      rl_weight integer,
      rl_height integer,
      gid serial NOT NULL,
      source integer,
      target integer,
      cost_len double precision,
      rcost_len double precision,
      one_way character varying(2),
      cost_time double precision,
      rcost_time double precision,
      x1 double precision,
      y1 double precision,
      x2 double precision,
      y2 double precision,
      to_cost double precision,
      rule text,
      isolated integer,
      CONSTRAINT itn_network_pkey PRIMARY KEY (gid)
    )
    WITH (
      OIDS=FALSE
    );
    ALTER TABLE itn_network
      OWNER TO postgres;
    COMMENT ON TABLE itn_network
      IS 'ITN network in routable format';
    
    -- Index: itn_network_geometry_gidx
    -- DROP INDEX itn_network_geometry_gidx;
    CREATE INDEX itn_network_geometry_gidx
      ON itn_network
      USING gist
      (geometry);
    
    -- Index: itn_network_source_idx
    -- DROP INDEX itn_network_source_idx;
    CREATE INDEX itn_network_source_idx
      ON itn_network
      USING btree
      (source);
    
    -- Index: itn_network_target_idx
    -- DROP INDEX itn_network_target_idx;
    CREATE INDEX itn_network_target_idx
      ON itn_network
      USING btree
      (target);

Create network build function
-----------------------------
Now we will create a function to use the roadlink table and the grade separation and one way views to populate the network table we created in the previous step.

    -- Function: create_itn_network()

    -- DROP FUNCTION create_itn_network();

    CREATE OR REPLACE FUNCTION create_itn_network()
	  RETURNS integer AS
	$BODY$
	  DECLARE
	    cur_rl CURSOR FOR SELECT rl.descriptivegroup, 
		rl.descriptiveterm, 
		rl.fid, 
		rl.dftname, 
		rl.roadname, 
		rl.length, 
		rl.natureofroad, 
		rl.wkb_geometry, 
		rl.ogc_fid, 
		ow.oneway_attr, 
		gs.gradeseparation_s, 
		gs.gradeseparation_e 
		FROM view_itn_gradeseparation gs 
		RIGHT JOIN (roadlink rl LEFT JOIN view_itn_oneway ow ON rl.fid = ow.directedlink_href) 
		ON rl.ogc_fid = gs.ogc_fid;
		
		v_descriptivegroup osmm_itn.roadlink.descriptivegroup%TYPE;
		v_descriptiveterm osmm_itn.roadlink.descriptiveterm%TYPE;
		v_fid osmm_itn.roadlink.fid%TYPE;
		v_itnroadlink_dftname osmm_itn.roadlink.dftname%TYPE;
		v_itnroadlink_roadname osmm_itn.roadlink.roadname%TYPE;
		v_length osmm_itn.roadlink.length%TYPE;
		v_natureofroad osmm_itn.roadlink.natureofroad%TYPE;
		v_polyline osmm_itn.roadlink.wkb_geometry%TYPE;
		v_primary_key osmm_itn.roadlink.ogc_fid%TYPE;
		v_oneway osmm_itn.itn_oneway.rl_attr_oneway%TYPE;
		v_rl_attribute integer;
		v_rl_roadname varchar(150);
		v_sql varchar(120);
		v_separation_s osmm_itn.view_itn_gradeseparation.gradeseparation_s%TYPE;
		v_separation_e osmm_itn.view_itn_gradeseparation.gradeseparation_e%TYPE;
		v_sep_s integer;
		v_sep_e integer;
		v_date date;
		v_ctr integer;
		v_total integer;
		
	   BEGIN
	-- TruncateStorage table;
		v_sql := 'TRUNCATE TABLE itn_network';
		EXECUTE v_sql;
		OPEN cur_rl;
		SELECT 'now'::timestamp INTO v_date;
		v_ctr := 1;
		v_total := 500;
		LOOP
		FETCH cur_rl INTO v_descriptivegroup, v_descriptiveterm, v_fid, v_itnroadlink_dftname, v_itnroadlink_roadname, v_length, v_natureofroad, v_polyline, v_primary_key, v_rl_attribute, v_oneway, v_separation_s,v_separation_e;
		EXIT WHEN NOT FOUND;
	--Build RoadName Text Output
		IF ((v_itnroadlink_roadname IS NULL) AND (v_itnroadlink_dftname IS NULL)) THEN 
		v_rl_roadname := v_descriptiveterm;
		ELSIF (v_itnroadlink_roadname IS NULL) THEN 
		v_rl_roadname := v_itnroadlink_dftname;
		ELSIF (v_itnroadlink_dftname IS NULL) THEN
		v_rl_roadname := v_itnroadlink_roadname;
		ELSE
		v_rl_roadname:= v_itnroadlink_roadname || ' (' || v_itnroadlink_dftname || ')';
		END IF;
		IF v_rl_attribute IS NULL THEN
		v_rl_attribute := 0;
		END IF;
	--Build Road Attribute Output including ONEWAY
		IF (v_natureofroad = 'Roundabout')THEN
		v_rl_attribute := v_rl_attribute + 8;
		ELSIF (v_natureofroad = 'Slip Road')THEN
		v_rl_attribute := v_rl_attribute + 7;
		ELSIF (v_descriptiveterm = 'A Road') THEN
		v_rl_attribute := v_rl_attribute + 2;
		ELSIF (v_descriptiveterm = 'B Road') THEN
		v_rl_attribute := v_rl_attribute + 3;
		ELSIF (v_descriptiveterm = 'Alley') THEN
		v_rl_attribute := v_rl_attribute + 6;
		ELSIF (v_descriptiveterm = 'Local Street') THEN
		v_rl_attribute := v_rl_attribute + 5;
		ELSIF (v_descriptiveterm = 'Minor Road') THEN
		v_rl_attribute := v_rl_attribute + 4;
		ELSIF (v_descriptiveterm = 'Motorway') THEN
		v_rl_attribute := v_rl_attribute + 1 + 64;
		ELSIF (v_descriptiveterm = 'Pedestrianised Street') THEN
		v_rl_attribute := v_rl_attribute + 9 + 128;
		ELSIF (v_descriptiveterm = 'Private Road - Publicly Accessible') THEN
		v_rl_attribute := v_rl_attribute + 10;
		ELSIF (v_descriptiveterm = 'Private Road - Restricted Access') THEN
		v_rl_attribute := v_rl_attribute + 11;
		ELSE
		v_rl_attribute := v_rl_attribute + 0;
		END IF;
	-- ADD ROAD GRADE SEPERATION
		IF v_separation_s = 1 THEN
		v_sep_s:= v_separation_s;
		ELSE
		v_sep_s:= 0;
		END IF;
		IF v_separation_e = 1 THEN
		v_sep_e:= v_separation_e;
		ELSE
		v_sep_e:= 0;
		END IF;
	--INSERT THE VALUES INTO THE TABLE	
		INSERT INTO itn_network(geometry, fkey_pkey, toid, dftname, roadname, natureofroad, length, descriptivegroup, descriptiveterm, rl_attribute, oneway, gradeseparation_s, gradeseparation_e, gid)
		VALUES(v_polyline, v_primary_key, v_fid, v_itnroadlink_dftname, v_itnroadlink_roadname, v_natureofroad, v_length, v_descriptivegroup, v_descriptiveterm, v_rl_attribute, v_oneway, v_sep_s, v_sep_e, v_primary_key);
		IF (v_ctr = v_total) THEN
		v_total := v_total + 500;
		END IF;
		v_ctr := v_ctr + 1;
		END LOOP;
		RETURN 1;
		CLOSE cur_rl;
	END;
	$BODY$
	  LANGUAGE plpgsql VOLATILE
	  COST 100;
	ALTER FUNCTION create_itn_network()
	  OWNER TO postgres;

Update one way field
--------------------
This joins the one way view to the network table and updates the "oneway" field with a 1 or 0 depending.

Update grade separation fields
------------------------------
This joins the grade separation view to the network table and updates the "gradeseparation_s" and "gradeseparation_e" fields with a 1 or 0 depending.

Rebuild elevated sections
-------------------------
Work in progress

Populate pgRouting fields
-------------------------
pgRouting requires a number of field to be present and populated in order for the routing algorithms to work.  First, update the coordinates for the start and end of the road link.

    UPDATE itn_network 
	SET x1 = st_x(st_startpoint(geometry)),
	  y1 = st_y(st_startpoint(geometry)),
	  x2 = st_x(st_endpoint(geometry)),
	  y2 = st_y(st_endpoint(geometry));

pgRouting use costs to determine the best routes across the network.  Costs can be time based (what is the quickest route?) or distance based (what is the shortest route?).  Reverse costs are also calculated which allows pgRouting to take into account one way streets and turn restrictions.

    UPDATE itn_network
	SET cost_len = ST_Length(geometry),
	  rcost_len = ST_Length(geometry);

Setting costs for one way streets using the "rl_attribute" set earlier in the network build function.

	UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute < 500;
	UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute < 500;
	UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute > 500 and rl_attribute < 1000;
	UPDATE itn_network SET rcost_len = cost_len*1000 WHERE rl_attribute > 500 and rl_attribute < 1000;
	UPDATE itn_network SET cost_len = ST_Length(geometry)*1000 WHERE rl_attribute > 1000;
	UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute > 1000;

pgRouting offers some tools to analyse your road network for valid one way streets and we can use those to check for errors.   First we need to populate the "one_way" field with the values required for the function to work:

	UPDATE itn_network SET one_way = 'B' WHERE rl_attribute < 500;
    UPDATE itn_network SET one_way = 'TF' WHERE rl_attribute > 500 AND rl_attribute < 1000;
    UPDATE itn_network SET one_way = 'FT' WHERE rl_attribute > 1000;

Calculate network time costs
----------------------------
One big update for all the road links.  Sets an average speed in km/h for each link depending on road class and nature of road.

    UPDATE itn_network SET 
		rl_speed = CASE WHEN descriptiveterm = 'A Road' AND natureofroad = 'Dual Carriageway' THEN 100
		WHEN descriptiveterm = 'A Road' AND natureofroad = 'Roundabout' THEN 40
		WHEN descriptiveterm = 'A Road' AND natureofroad = 'Single Carriageway' THEN 70
		WHEN descriptiveterm = 'A Road' AND natureofroad = 'Slip Road' THEN 40
		WHEN descriptiveterm = 'A Road' AND natureofroad = 'Traffic Island Link' THEN 40
		WHEN descriptiveterm = 'A Road' AND natureofroad = 'Traffic Island Link At Junction' THEN 40
		WHEN descriptiveterm = 'Alley' AND natureofroad = 'Single Carriageway' THEN 5
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Dual Carriageway' THEN 80
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Roundabout' THEN 40
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Single Carriageway' THEN 60
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Slip Road' THEN 40
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Traffic Island Link' THEN 40
		WHEN descriptiveterm = 'B Road' AND natureofroad = 'Traffic Island Link At Junction' THEN 40
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Dual Carriageway' THEN 40
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Roundabout' THEN 30
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Single Carriageway' THEN 40
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Slip Road' THEN 30
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Traffic Island Link' THEN 30
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Traffic Island Link At Junction' THEN 30
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Dual Carriageway' THEN 50
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Roundabout' THEN 30
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Single Carriageway' THEN 50
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Slip Road' THEN 30
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Traffic Island Link' THEN 30
		WHEN descriptiveterm = 'Minor Road' AND natureofroad = 'Traffic Island Link At Junction' THEN 30
		WHEN descriptiveterm = 'Motorway' AND natureofroad = 'Dual Carriageway' THEN 120
		WHEN descriptiveterm = 'Motorway' AND natureofroad = 'Roundabout' THEN 40
		WHEN descriptiveterm = 'Motorway' AND natureofroad = 'Single Carriageway' THEN 100
		WHEN descriptiveterm = 'Motorway' AND natureofroad = 'Slip Road' THEN 40
		WHEN descriptiveterm = 'Pedestrianised Street' AND natureofroad = 'Single Carriageway' THEN 1
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Dual Carriageway' THEN 80
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Enclosed Traffic Area Link' THEN 40
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Roundabout' THEN 40
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Single Carriageway' THEN 60
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Slip Road' THEN 40
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Traffic Island Link' THEN 40
		WHEN descriptiveterm = 'Private Road - Publicly Accessible' AND natureofroad = 'Traffic Island Link At Junction' THEN 40
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Dual Carriageway' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Enclosed Traffic Area Link' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Roundabout' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Single Carriageway' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Slip Road' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Traffic Island Link' THEN 5
		WHEN descriptiveterm = 'Private Road - Restricted Access' AND natureofroad = 'Traffic Island Link At Junction' THEN 5
		ELSE null END;

Then use the speed and road link length to calculate a time cost for each road link.

    UPDATE itn_network SET
    cost_time = CASE
        WHEN one_way='TF' THEN 10000.0
        ELSE cost_len/1000.0/rl_speed::numeric*3600.0
        END,
    rcost_time = CASE
        WHEN one_way='FT' THEN 10000.0
        ELSE cost_len/1000.0/rl_speed::numeric*3600.0
        END;

Create no entry restrictions
----------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/616.jpg" alt="No Entry" width="206px">
A somewhat complex process follows wherein a view of oneway streets is created and then subsequent views of all road links that connect to the end of the one way street and have a restricted turn into it.  The views are combined into a final table in pgRouting turn restriction format.

Create no turn restrictions
---------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/613.jpg" alt="No Turn" width="206px">
Builds a turn table in pgRouting format from all links in the network with a "No Turn" restriction. The turn is defined as the series of links which form the turn. The turn restriction table lists the restrictions that prevent a route across the network using those links.

Turns can be made up of a number of edges, or links, and the views below select out each link in turn.

First link

Second link

Third link

Combined view of all turn restricted links

Create the turn restriction table

Create mandatory turn restrictions
----------------------------------
![Mandatory Turn](images/609A.jpg)

Build pgRouting topology
------------------------
    
    SELECT pgr_createTopology('osmm_itn.itn_network', 0.001, 'wkb_geometry', 'gid', 'source', 'target');
    
Analyse network topology
------------------------
It's a good idea to analyse your network topology once create to give you an idea of any potential errors.

    SELECT pgr_analyzeGraph('osmm_itn.itn_network', 0.001, 'wkb_geometry', 'gid', 'source', 'target'); 

Get some stats about your one way streets as well.
    
    SELECT pgr_analyzeOneway('osmm_itn.itn_network',
            ARRAY['', 'B', 'TF'],
            ARRAY['', 'B', 'FT'],
            ARRAY['', 'B', 'FT'],
            ARRAY['', 'B', 'TF'],
            oneway:='one_way'
            );


pgRouting and QGIS
------------------

References
----------
http://www.ordnancesurvey.co.uk/business-and-government/products/itn-layer.html

https://github.com/AstunTechnology/Loader

http://pgrouting.org/

http://www.archaeogeek.com/blog/2012/08/17/pgrouting-with-ordnance-survey-itn-data/

http://anitagraser.com/?s=pgrouting
