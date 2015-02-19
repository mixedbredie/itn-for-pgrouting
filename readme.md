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

To run the function and populate the itn_network table do:

	SELECT create_itn_network();
	
Wait a while (depending on how large your network is) and then check the table when the function has finished running.  So now we have a table with all the network fields in it and some of the information populated.  Let's add some more.

Populate pgRouting fields
-------------------------
pgRouting requires a number of field to be present and populated in order for the routing algorithms to work.  First, update the coordinates for the start and end of the road link.  This is used in the _astar_, _TSP_ and _bdAstar_ functions.

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

	UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute < 500; --two way streets
	UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute < 500; --two way streets
	UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute > 500 and rl_attribute < 1000; --one way streets in digitised direction
	UPDATE itn_network SET rcost_len = cost_len*1000 WHERE rl_attribute > 500 and rl_attribute < 1000; --one way streets in digitised direction
	UPDATE itn_network SET cost_len = ST_Length(geometry)*1000 WHERE rl_attribute > 1000; --one way streets against digitised direction
	UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute > 1000; --one way streets against digitised direction

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
		WHEN descriptiveterm = 'Local Street' AND natureofroad = 'Enclosed Traffic Area Link' THEN 10
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
        
Check the table to make sure the fields have been updated with appropriate values.  Now it's time to build the network.

Build pgRouting topology
------------------------
    
    SELECT pgr_createTopology('osmm_itn.itn_network', 0.001, 'wkb_geometry', 'gid', 'source', 'target');
    
This create a new table in the database called itn_network_vertices_pgr and contains the nodes joining the links of the network.
    
Analyse network topology
------------------------
It's a good idea to analyse your network topology once create to give you an idea of any potential errors.

    SELECT pgr_analyzeGraph('osmm_itn.itn_network', 0.001, 'wkb_geometry', 'gid', 'source', 'target'); 

Find links with problems

    SELECT * FROM itn_network_vertices_pgr WHERE chk = 1;
    
Find links with deadends

    SELECT * FROM itn_network_vertices_pgr WHERE cnt = 1;
    
Find isolated segments (deadends at both ends)

    SELECT * FROM itn_network a, itn_network_vertices_pgr b, itn_network_vertices_pgr c WHERE a.source = b.id AND b.cnt = 1 AND a.target = c.id AND c.cnt = 1;

Get some stats about your one way streets as well.
    
    SELECT pgr_analyzeOneway('osmm_itn.itn_network',
            ARRAY['', 'B', 'TF'],
            ARRAY['', 'B', 'FT'],
            ARRAY['', 'B', 'FT'],
            ARRAY['', 'B', 'TF'],
            oneway:='one_way'
            );

Find nodes with potential problems

    SELECT * FROM itn_network_vertices_pgr WHERE ein = 0 OR eout = 0;
    
Find the links attached to the problem nodes

    SELECT gid FROM itn_network a, itn_network_vertices_pgr b WHERE a.source=b.id AND ein=0 OR eout=0
      UNION
    SELECT gid FROM itn_network a, itn_network_vertices_pgr b WHERE a.target=b.id AND ein=0 OR eout=0;

pgRouting and QGIS
------------------
Your network table is now ready for some quick and dirty routing.  Install the pgRouting Layer plugin in QGIS and you have an easy to use interface to all the pgRouting functionality. Plugin details here: http://plugins.qgis.org/plugins/pgRoutingLayer/

Further enhancements
--------------------
The network can be enhanced by modelling no turn restrictions, mandatory turn restrictions, grade separations and no entry streets.  The sections below outline the process.  There is much room for improvement here and this section may change as I work out better ways of doing things.

Create no turn restrictions
---------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/613.jpg" alt="No Turn" width="206px">
Builds a turn table in pgRouting format from all links in the network with a "No Turn" restriction. The turn is defined as the series of links which form the turn. The turn restriction table lists the restrictions that prevent a route across the network using those links.

Create some views used to start the No Turn build process:

	-- View: view_rrirl_one_way
	-- DROP VIEW view_rrirl_one_way;
	CREATE OR REPLACE VIEW view_rrirl_one_way AS 
		SELECT rrirl.roadlink_fid, 
		array_to_string(rri.directedlink_orientation,', ') AS directedlink_orientation, array_to_string(rri.environmentqualifier_instruction,', ') AS environmentqualifier, 
		rri.fid AS rri_fid, 
		rl.wkb_geometry
		FROM roadrouteinformation rri, roadrouteinformation_roadlink rrirl, roadlink rl
		WHERE rrirl.roadrouteinformation_fid = rri.fid 
		AND rrirl.roadlink_fid = rl.fid
		AND rri.environmentqualifier_instruction::text = '{"One Way"}'::text;
	ALTER TABLE view_rrirl_one_way
	OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_one_way
	IS 'ITN Road Routing Information Road Link One Way Streets – for turn restrictions';
  
	-- View: view_rl_one_way
	-- DROP VIEW view_rl_one_way;
	CREATE OR REPLACE VIEW view_rl_one_way AS 
		SELECT rl.descriptivegroup, 
		rl.descriptiveterm, 
		rl.fid AS fid2, 
		rl.length, 
		rl.natureofroad, 
		rl.wkb_geometry, 
		rl.ogc_fid, 
		rl.dftname, 
		rl.roadname, 
		rl.theme, 
		ow.directedlink_orientation AS one_way
	FROM roadlink rl, view_rrirl_one_way ow
	WHERE rl.fid::text = ow.roadlink_fid::text;
	ALTER TABLE view_rl_one_way
	OWNER TO postgres;
	COMMENT ON VIEW view_rl_one_way
	IS 'ITN Roadlink One Way Streets – for turn restrictions';

Turns can be made up of a number of edges, or links, and the views below select out each link in turn.  The query below will tell you how many views to create - one for each value in the table.  For my example, ITN for Tayside, I have three values:

	SELECT DISTINCT roadlink_order FROM roadrouteinformation_roadlink;

First link (these take some time - improvements?)

	CREATE OR REPLACE VIEW view_rrirl_nt1 AS 
	 SELECT rrirl.roadlink_fid,
	    rri.directedlink_orientation,
	    rrirl.roadlink_order,
	    array_to_string(rri.environmentqualifier_instruction, ', '::text) AS environmentqualifier_instruction,
	    rri.ogc_fid,
	    array_to_string(rri.vehiclequalifier_type, ', '::text) AS array_to_string,
	    rri.datetimequalifier,
	    rl.wkb_geometry,
	    rl.ogc_fid AS objectid,
	    rl.fid2 AS fid,
	    nt_i.edgefcid AS edge1fcid,
	    nt_i.edgepos AS edge1pos
	   FROM roadrouteinformation rri,
	    roadrouteinformation_roadlink rrirl,
	    view_rl_one_way rl,
	    itn_rrirl_nt_info nt_i
	  WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"No Turn"}'::character varying[] AND rl.fid2::text = rrirl.roadlink_fid AND rrirl.roadlink_order = 1;
	
	ALTER TABLE view_rrirl_nt1
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_nt1
	  IS 'No Turn First Link';

Second link

	CREATE OR REPLACE VIEW view_rrirl_nt2 AS 
	 SELECT rrirl.roadlink_fid,
	    rri.directedlink_orientation,
	    rrirl.roadlink_order,
	    array_to_string(rri.environmentqualifier_instruction, ', '::text) AS environmentqualifier_instruction,
	    rri.ogc_fid,
	    array_to_string(rri.vehiclequalifier_type, ', '::text) AS array_to_string,
	    rri.datetimequalifier,
	    rl.wkb_geometry,
	    rl.ogc_fid AS objectid,
	    rl.fid2 AS fid,
	    nt_i.edgefcid AS edge2fcid,
	    nt_i.edgepos AS edge2pos
	   FROM roadrouteinformation rri,
	    roadrouteinformation_roadlink rrirl,
	    view_rl_one_way rl,
	    itn_rrirl_nt_info nt_i
	  WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"No Turn"}'::character varying[] AND rl.fid2::text = rrirl.roadlink_fid AND rrirl.roadlink_order = 2;
	
	ALTER TABLE view_rrirl_nt2
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_nt2
	  IS 'No Turn Second Link';

Third link

	CREATE OR REPLACE VIEW view_rrirl_nt3 AS 
	 SELECT rrirl.roadlink_fid,
	    rri.directedlink_orientation,
	    rrirl.roadlink_order,
	    array_to_string(rri.environmentqualifier_instruction, ', '::text) AS environmentqualifier_instruction,
	    rri.ogc_fid,
	    array_to_string(rri.vehiclequalifier_type, ', '::text) AS array_to_string,
	    rri.datetimequalifier,
	    rl.wkb_geometry,
	    rl.ogc_fid AS objectid,
	    rl.fid2 AS fid,
	    nt_i.edgefcid AS edge3fcid,
	    nt_i.edgepos AS edge3pos
	   FROM roadrouteinformation rri,
	    roadrouteinformation_roadlink rrirl,
	    view_rl_one_way rl,
	    itn_rrirl_nt_info nt_i
	  WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"No Turn"}'::character varying[] AND rl.fid2::text = rrirl.roadlink_fid AND rrirl.roadlink_order = 3;
	
	ALTER TABLE view_rrirl_nt3
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_nt3
	  IS 'No Turn Third Link';

Combined view of all turn restricted links

	CREATE OR REPLACE VIEW view_rrirl_nt AS 
	 SELECT nt1.objectid,
	        CASE
	            WHEN nt1.directedlink_orientation[1]::text = '+'::text THEN 'y'::text
	            ELSE 'n'::text
	        END AS edge1end,
	    COALESCE(nt1.edge1fcid) AS edge1fcid,
	    COALESCE(nt1.ogc_fid, 0) AS edge1fid,
	    COALESCE(nt1.edge1pos, 0::double precision) AS edge1pos,
	    COALESCE(nt2.edge2fcid) AS edge2fcid,
	    COALESCE(nt2.ogc_fid, 0) AS edge2fid,
	    COALESCE(nt2.edge2pos, 0::double precision) AS edge2pos,
	    COALESCE(nt3.edge3fcid) AS edge3fcid,
	    COALESCE(nt3.ogc_fid, 0) AS edge3fid,
	    COALESCE(nt3.edge3pos, 0::double precision) AS edge3pos,
	    nt1.wkb_geometry
	   FROM itn_rrirl_nt_info nt_i,
	    view_rrirl_nt1 nt1
	   LEFT JOIN view_rrirl_nt2 nt2 ON nt1.objectid = nt2.objectid
	   LEFT JOIN view_rrirl_nt3 nt3 ON nt1.objectid = nt3.objectid;
	
	ALTER TABLE view_rrirl_nt
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_nt
	  IS 'No Turn All roadlinks in turn restriction';

Create the turn restriction table in pgRouting format

	CREATE TABLE itn_nt_restrictions (
		rid integer NOT NULL,
		to_cost double precision,
		teid integer,
		feid integer,
		via text--,
		--CONSTRAINT itn_nt_restrictions_pkey PRIMARY KEY (rid)
	)
	WITH (
	  OIDS=FALSE
	);
	ALTER TABLE itn_nt_restrictions
	  OWNER TO postgres;
	COMMENT ON TABLE itn_nt_restrictions
	  IS 'ITN No Turn Restrictions';

Populate the turn restriction table from the combined view

	INSERT INTO itn_nt_restrictions(rid,feid,teid)
  	  SELECT objectid AS rid,edge1fid AS feid,edge2fid AS teid FROM view_rrirl_nt v
  	  WHERE v.edge2fid <> 0
  	  AND v.edge2fid NOT IN (SELECT DISTINCT t.teid FROM itn_nt_restrictions t WHERE t.rid = v.objectid);

	INSERT INTO itn_nt_restrictions(rid,feid,teid)
	  SELECT objectid AS rid,edge1fid AS feid,edge3fid AS teid FROM view_rrirl_nt v
	  WHERE v.edge3fid <> 0
	  AND v.edge3fid NOT IN (SELECT DISTINCT t.teid FROM itn_nt_restrictions t WHERE t.rid = v.objectid);
	  
	UPDATE itn_nt_restrictions SET to_cost = 9999;

Test the turn restrictions using the Turn Restricted Shortest Path (TRSP) algorithm

	SELECT * FROM pgr_trsp(
	    'SELECT gid AS id, source::integer, target::integer,cost_len AS cost,rcost_len AS reverse_cost from itn_network',
	    3480,    -- edge_id for start
	    0.5,  -- midpoint of edge
	    3033,    -- edge_id of route end
	    0.5,  -- midpoint of edge
	    false, -- directed graph?
	    false, -- has_reverse_cost?
	              -- include the turn restrictions
	    'SELECT to_cost, teid AS target_id, feid||coalesce('',''||via,'''') AS via_path FROM itn_nt_restrictions');

Create mandatory turn restrictions
----------------------------------
![Mandatory Turn](images/609A.jpg)

The first view selects out the first link, or approach road, in the mandatory turn.

	CREATE OR REPLACE VIEW view_rrirl_mt1 AS
	 SELECT rrirl.roadlink_fid,
	    rri.directedlink_orientation,
	    rrirl.roadlink_order,
	    rl.ogc_fid AS objectid,
	    rl.fid AS rl_fid,
	    rri.fid AS rri_fid,
	    rl.wkb_geometry
	   FROM roadrouteinformation rri, roadrouteinformation_roadlink rrirl, roadlink rl
	  WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"Mandatory Turn"}'::character varying[] AND rrirl.roadlink_order = 1 AND rl.fid::text = rrirl.roadlink_fid;
	
	ALTER TABLE view_rrirl_mt1
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_mt1
	  IS 'Approach Road for ITN Mandatory Turn Restrictions';

The second view selects out the second link, or exit road, in the mandatory turn.  
  
	CREATE OR REPLACE VIEW view_rrirl_mt2 AS
		SELECT rrirl.roadlink_fid, 
		rri.directedlink_orientation, 
		rrirl.roadlink_order, 
		rl.ogc_fid AS objectid,
		rl.fid AS rl_fid,
		rri.fid AS rri_fid,
		rl.wkb_geometry   
		FROM roadrouteinformation rri, roadrouteinformation_roadlink rrirl, roadlink rl
		WHERE 
		rrirl.roadrouteinformation_fid = rri.fid 
		AND rri.environmentqualifier_instruction = '{"Mandatory Turn"}' and rrirl.roadlink_order = 2
		and rl.fid = rrirl.roadlink_fid;
	COMMENT ON VIEW view_rrirl_mt2
	  IS 'Exit Road for ITN Mandatory Turn Restrictions';

Select the nodes on the approach links

	CREATE OR REPLACE VIEW view_temp_rdnd_point AS
	 SELECT rn.fid AS rn_fid,
	    rn.wkb_geometry,
	    mt1.rl_fid,
	    mt1.rri_fid,
	    mt1.objectid,
	    mt1.directedlink_orientation,
	    mt1.roadlink_order
	   FROM roadnode rn,
	    view_rrirl_mt1 mt1,
	    roadlink_roadnode rlrn
	  WHERE mt1.rl_fid::text = rlrn.roadlink_fid::text AND rn.fid::text = rlrn.roadnode_fid;
	ALTER TABLE view_temp_rdnd_point
	  OWNER TO postgres;
	COMMENT ON VIEW view_temp_rdnd_point
	  IS 'MT Nodes on approach links';
	  
Select the nodes on the exit links

	CREATE OR REPLACE VIEW view_temp_rdnd_point2 AS
	 SELECT rn.fid AS rn_fid,
	    rn.wkb_geometry,
	    mt2.rl_fid,
	    mt2.rri_fid,
	    mt2.objectid,
	    mt2.directedlink_orientation,
	    mt2.roadlink_order
	   FROM roadnode rn,
	    view_rrirl_mt2 mt2,
	    roadlink_roadnode rlrn
	  WHERE mt2.rl_fid::text = rlrn.roadlink_fid::text AND rn.fid::text = rlrn.roadnode_fid;
	ALTER TABLE view_temp_rdnd_point2
	  OWNER TO postgres;
	COMMENT ON VIEW view_temp_rdnd_point2
	  IS 'MT Nodes on exit links';
	  
Select the junction corner point

	CREATE OR REPLACE VIEW view_mt_junction_point AS
	 SELECT rn.rn_fid,
	    rn.directedlink_orientation,
	    rn.rl_fid AS rl_fid1,
	    rn.objectid AS in_road_id,
	    rn2.rl_fid AS rl_fid2,
	    rn2.objectid AS out_road_id,
	    rn.rri_fid,
	    rn.wkb_geometry
	   FROM view_temp_rdnd_point rn,
	    view_temp_rdnd_point2 rn2
	  WHERE st_equals(rn.wkb_geometry, rn2.wkb_geometry) AND (rn.directedlink_orientation[1]::text = '-'::text OR rn.directedlink_orientation[1]::text = '+'::text) AND rn.rri_fid::text = rn2.rri_fid::text AND rn.rl_fid::text <> rn2.rl_fid::text
	ALTER TABLE view_mt_junction_point
	  OWNER TO postgres;
	COMMENT ON VIEW view_mt_junction_point
	  IS 'MT Nodes at junction point of MT';
	  
Create a view of the links in the mandatory turn

	CREATE OR REPLACE VIEW view_mt_junction_links AS
	 SELECT DISTINCT rlrn.roadlink_fid,
	    jp.rl_fid1,
	    jp.in_road_id,
	    jp.rl_fid2,
	    jp.out_road_id,
	    jp.directedlink_orientation,
	    jp.rri_fid,
	    rl.ogc_fid AS objectid,
	    rl.wkb_geometry
	   FROM roadlink_roadnode rlrn,
	    roadlink rl,
	    itn_mt_junction_point jp
	  WHERE jp.rn_fid::text = rlrn.roadnode_fid AND rlrn.roadlink_fid::text = rl.fid::text;
	ALTER TABLE view_mt_junction_links
	  OWNER TO postgres;
	COMMENT ON VIEW view_mt_junction_links
	  IS 'MT IN and OUT links at junction point of MT';

Create a view of the no turn restrictions in the mandatory turn junction

	CREATE OR REPLACE VIEW view_mt_junction_nt_links AS
	 SELECT DISTINCT rlrn.roadlink_fid,
	        CASE
	            WHEN rlrn.roadlink_fid::text <> jp.rl_fid1::text THEN 2
	            ELSE 1
	        END AS join_order,
	    jp.rl_fid1,
	    rl.ogc_fid AS objectid,
	    jp.rri_fid,
	    rl.wkb_geometry
	   FROM roadlink_roadnode rlrn,
	    roadlink rl,
	    itn_mt_junction_point jp
	  WHERE jp.rn_fid::text = rlrn.roadnode_fid AND rlrn.roadlink_fid::text = rl.fid::text AND NOT (rlrn.roadlink_fid::text IN ( SELECT rrirl.roadlink_fid
	           FROM roadrouteinformation rri,
	            roadrouteinformation_roadlink rrirl,
	            roadlink rl_1
	          WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"Mandatory Turn"}'::character varying[] AND rrirl.roadlink_order = 1 AND rl_1.fid::text = rrirl.roadlink_fid)) AND NOT (rlrn.roadlink_fid::text IN ( SELECT rrirl.roadlink_fid
	           FROM roadrouteinformation rri,
	            roadrouteinformation_roadlink rrirl,
	            roadlink rl_1
	          WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"Mandatory Turn"}'::character varying[] AND rrirl.roadlink_order = 2 AND rl_1.fid::text = rrirl.roadlink_fid));
	ALTER TABLE view_mt_junction_nt_links
	  OWNER TO postgres;
	COMMENT ON VIEW view_mt_junction_nt_links
	  IS 'MT All NO TURN links at junction point of MT';
	  
These views are turned into a turn restriction table.

	CREATE OR REPLACE VIEW view_rrirl_mt_nt AS
	SELECT row_number() OVER () AS objectid,
		CASE WHEN NT1.directedlink_orientation = '{+}' THEN 'y' ELSE 'n' END AS edge1end,
		E1.ogc_fid AS edge1fid,
		E2.ogc_fid AS edge2fid,
	FROM itn_mt_junction_links nt1, 
		roadrouteinformation rri, 
		view_rl_one_way e1,
		view_rl_one_way e2
	WHERE (nt1.rri_fid = rri.ogc_fid) 
		AND (E1.fid2 = nt1.roadlink1) 
		AND (E2.fid2 = nt1.roadlink2); 
	COMMENT ON VIEW view_rrirl_mt_nt
	  IS 'MT turn restrictions'; 

Create the mandatory turn restriction table

	CREATE TABLE itn_mt_nt_restrictions
	(
	  rid integer NOT NULL,
	  to_cost double precision,
	  teid integer,
	  feid integer,
	  via text
	)
	WITH (
	  OIDS=FALSE
	);
	ALTER TABLE itn_mt_nt_restrictions
	  OWNER TO postgres;
	COMMENT ON TABLE itn_mt_nt_restrictions
	  IS 'ITN No Turn Restrictions';

Insert the values into the turn restriction table
  
	INSERT INTO itn_mt_nt_restrictions(rid,feid,teid)
	  SELECT objectid AS rid,
	  edge1fid AS feid,
	  edge2fid AS teid 
	  FROM view_rrirl_mt_nt v
	  WHERE v.edge2fid <> 0
	  AND v.edge2fid NOT IN (SELECT DISTINCT t.teid FROM itn_mt_nt_restrictions t WHERE t.rid = v.objectid); 
	  
	UPDATE itn_mt_nt_restrictions SET to_cost = 9999;

Create no entry restrictions
----------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/616.jpg" alt="No Entry" width="206px">
A somewhat complex process follows wherein a view of oneway streets is created and then subsequent views of all road links that connect to the end of the one way street and have a restricted turn into it.  The views are combined into a final table in pgRouting turn restriction format.

Create a view to show the first link of the No Entry restriction.

	CREATE OR REPLACE VIEW view_rrirl_ne1 AS 
	 SELECT rrirl.roadlink_fid,
	    rri.directedlink_orientation,
	    rrirl.roadlink_order,
	    rl.ogc_fid,
	    rri.ogc_fid AS rri_fid,
	    rl.wkb_geometry
	   FROM roadrouteinformation rri,
	    roadrouteinformation_roadlink rrirl,
	    roadlink rl
	  WHERE rrirl.roadrouteinformation_fid::text = rri.fid::text AND rri.environmentqualifier_instruction = '{"No Entry"}'::character varying[] AND rrirl.roadlink_order = 1 AND rl.fid::text = rrirl.roadlink_fid;
	
	ALTER TABLE view_rrirl_ne1
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_ne1
	  IS 'No entry first link';
	  
Find the node point on the corner of the No Entry turn:

	CREATE OR REPLACE VIEW view_rrirl_nept AS 
	 SELECT ne.roadlink_fid,
	    ne.directedlink_orientation,
	    ne.ogc_fid,
	    ne.rri_fid,
	    rlrn.roadnode_fid,
	    rn.wkb_geometry
	   FROM view_rrirl_ne1 ne,
	    roadlink_roadnode rlrn,
	    roadnode rn
	  WHERE ne.directedlink_orientation[1]::text <> rlrn.directednode_orientation::text AND ne.roadlink_fid = rlrn.roadlink_fid::text AND rlrn.roadnode_fid = rn.fid::text;
	
	ALTER TABLE view_rrirl_nept
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_nept
	  IS 'Corner of the No Entry feature';
	  
Find the other links that meet at the No Entry point:

	CREATE OR REPLACE VIEW view_rrirl_xyne AS 
	 SELECT pne.roadlink_fid AS roadlink1,
	    pne.ogc_fid AS ogc_fid1,
	    rl.fid AS roadlink2,
	    rl.ogc_fid AS ogc_fid2,
	    rlrn.directednode_orientation,
	    pne.rri_fid,
	    pne.roadnode_fid,
	    rl.wkb_geometry
	   FROM view_rrirl_nept pne,
	    roadlink_roadnode rlrn
	   RIGHT JOIN roadlink rl ON rlrn.roadlink_fid::text = rl.fid::text
	  WHERE pne.roadnode_fid = rlrn.roadnode_fid AND rl.fid::text <> pne.roadlink_fid
	  ORDER BY pne.ogc_fid;
	
	ALTER TABLE view_rrirl_xyne
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_xyne
	  IS 'ITN Roadlinks with the directed node of No Entry';
	  
Create the initial No Entry turn restrictions:

	CREATE OR REPLACE VIEW view_rrirl_ne_nt AS 
	 SELECT
	        CASE
	            WHEN nt1.directednode_orientation::text = '-'::text THEN 'y'::text
	            ELSE 'n'::text
	        END AS edge1end,
	    COALESCE(nt1.ogc_fid2) AS edge1fid,
	    0.5 AS edge1pos,
	    COALESCE(nt1.ogc_fid1) AS edge2fid,
	    0.5 AS edge2pos,
	    row_number() OVER () AS objectid
	   FROM view_rrirl_xyne2 nt1,
	    roadrouteinformation rri
	  WHERE nt1.rri_fid = rri.ogc_fid;
	
	ALTER TABLE view_rrirl_ne_nt
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_ne_nt
	  IS 'No Entry Turn Restrictions';
		  
Create a No Entry turn restriction table:

	CREATE TABLE itn_ne_nt_restrictions
	(
	  rid integer NOT NULL,
	  to_cost double precision,
	  teid integer,
	  feid integer,
	  via text
	)
	WITH (
	  OIDS=FALSE
	);
	ALTER TABLE itn_ne_nt_restrictions
	  OWNER TO postgres;
	COMMENT ON TABLE itn_ne_nt_restrictions
	  IS 'ITN No Turn Restrictions';

Insert the values into the turn restriction table:

	INSERT INTO itn_ne_nt_restrictions(rid,feid,teid)
	  SELECT objectid AS rid,
	  edge1fid AS feid,
	  edge2fid AS teid 
	  FROM view_rrirl_ne_nt v
	  WHERE v.edge2fid <> 0
	  AND v.edge2fid NOT IN (SELECT DISTINCT t.teid FROM itn_ne_nt_restrictions t WHERE t.rid = v.objectid);
	  
	UPDATE itn_ne_nt_restrictions SET to_cost = 9999;

Grade separation turn restrictions
----------------------------------
<img src="https://github.com/mixedbredie/itn-for-pgrouting/raw/master/images/low_bridge.jpg" alt="Grade separation" width="206px">
As an alternative to merging the elevate roadlinks into single sections you can build a turn restriction table that prevents turns to and from links with different grade separations or heights.

Build up an initial view of all nodes in the network

	CREATE OR REPLACE VIEW view_rrirl_gs AS 
	 SELECT rl.ogc_fid,
	    rl.fid,
	    rlrn.roadnode_fid,
	    rlrn.directednode_orientation,
	    rlrn.directednode_gradeseparation,
	    rn.wkb_geometry
	   FROM roadlink rl,
	    roadlink_roadnode rlrn,
	    roadnode rn
	  WHERE rlrn.roadlink_fid::text = rl.fid::text AND rn.fid::text = rlrn.roadnode_fid;
	
	ALTER TABLE view_rrirl_gs
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_gs
	  IS 'Grade separation nodes';

Find all the links at nodes with different heights (grade separation)
	  
	CREATE OR REPLACE VIEW view_rrirl_gs1 AS 
	 SELECT gs.roadnode_fid AS gs_node,
	    rlrn.roadnode_fid AS rlrn_node,
	    rlrn.directednode_gradeseparation AS rlrn_gs,
	    gs.directednode_gradeseparation AS gs_gs,
	    rlrn.roadlink_fid,
	    gs.fid AS roadlink1,
	    gs.ogc_fid AS ogc_fid1,
	    gs.directednode_orientation,
	    rl.fid AS roadlink2,
	    rl.ogc_fid AS ogc_fid2,
	    rl.wkb_geometry
	   FROM roadlink_roadnode rlrn,
	    view_rrirl_gs gs,
	    roadlink rl
	  WHERE rlrn.roadnode_fid = gs.roadnode_fid AND rlrn.directednode_gradeseparation <> gs.directednode_gradeseparation AND rlrn.roadlink_fid::text = rl.fid::text;
	
	ALTER TABLE view_rrirl_gs1
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_gs1
	  IS 'Grade separation links at nodes with different heights';

Build up a set of turn restrictions
  
	CREATE OR REPLACE VIEW view_rrirl_gs_nt AS 
	 SELECT row_number() OVER () AS objectid,
	        CASE
	            WHEN nt1.orientation::text = '{+}'::text THEN 'y'::text
	            ELSE 'n'::text
	        END AS edge1end,
	    nt1.ogc_fid1 AS edge1fid,
	    0.5 AS edge1pos,
	    nt1.ogc_fid2 AS edge2fid,
	    0.5 AS edge2pos
	   FROM view_rrirl_gs1 nt1;
	
	ALTER TABLE view_rrirl_gs_nt
	  OWNER TO postgres;
	COMMENT ON VIEW view_rrirl_gs_nt
	  IS 'Grade separation turn restrictions';

Create a grade separation turn restriction table in pgRouting format

	CREATE TABLE itn_gs_nt_restrictions
	(
	  rid integer NOT NULL,
	  to_cost double precision,
	  teid integer,
	  feid integer,
	  via text
	)
	WITH (
	  OIDS=FALSE
	);
	ALTER TABLE itn_gs_nt_restrictions
	  OWNER TO postgres;
	COMMENT ON TABLE itn_gs_nt_restrictions
	  IS 'ITN Grade Separated Turn Restrictions';
	  
Insert the values into the turn restriction table

	INSERT INTO itn_gs_nt_restrictions(rid,feid,teid)
	  SELECT objectid AS rid,
	  edge1fid AS feid,
	  edge2fid AS teid 
	  FROM view_rrirl_gs_nt v
	  WHERE v.edge2fid <> 0
	  AND v.edge2fid NOT IN (SELECT DISTINCT t.teid FROM itn_gs_nt_restrictions t WHERE t.rid = v.objectid);
	  
	UPDATE itn_gs_nt_restrictions SET to_cost = 9999;

Test this in QGIS with the pgRouting Layer plugin and the TRSP(vertext) or (edge) functions.  The turn restriction SQL to use is:

	'select to_cost, teid as target_id, feid||coalesce('',''||via,'''') as via_path from itn_gs_nt_restrictions'

This eliminates the need to mess around with merging elevated geometries and just uses the turn restrictions and costs to route across the network.

Combine Turn Restrictions
-------------------------

We have now created four turn restriction tables - no entries, mandatory turns, no turns and grade separations.

	itn_nt_restrictions
	itn_gs_nt_restrictions
	itn_mt_nt_restrictions
	itn_ne_nt_restrictions

These can all be tested in QGIS using the Trun Restricted Shortest Path function.  Let's combine these so all turn restrictions are in one table. The No Turn restrictions already exist so we'll add the other turns to the same table:

	INSERT INTO itn_nt_restrictions(rid,feid,teid)
	  SELECT row_number() over() AS rid,
	  v.feid AS feid,
	  v.teid AS teid
	  FROM itn_gs_nt_restrictions v
	  WHERE v.teid <> 0
	  AND v.teid NOT IN (SELECT DISTINCT t.teid 
	  FROM itn_nt_restrictions t 
	  WHERE t.rid = v.rid) 
	UNION
	  SELECT row_number() over() AS rid,
	  v.feid AS feid,
	  v.teid AS teid
	  FROM itn_mt_nt_restrictions v
	  WHERE v.teid <> 0
	  AND v.teid NOT IN (SELECT DISTINCT t.teid 
	  FROM itn_nt_restrictions t 
	  WHERE t.rid = v.rid)
	UNION
	  SELECT row_number() over() AS rid,
	  v.feid AS feid,
	  v.teid AS teid
	  FROM itn_ne_nt_restrictions v
	  WHERE v.teid <> 0
	  AND v.teid NOT IN (SELECT DISTINCT t.teid 
	  FROM itn_nt_restrictions t 
	  WHERE t.rid = v.rid);

Use the following SQL in QGIS to test the turn restrictions:

	'select to_cost, teid as target_id, feid||coalesce('',''||via,'''') as via_path from itn_nt_restrictions'

Other bits
----------
ITN contains a lot of information in the RRI tables.  You can add height restrictions to your network.

First, create a view to cross reference the roadlink and roadlinkinformation tables.

	CREATE OR REPLACE VIEW roadlinkinformation_roadlink AS 
	 SELECT a.roadlinkinformation_fid,
	    replace(a.roadlink_fid, '#'::text, ''::text) AS roadlink_fid
	   FROM ( SELECT roadlinkinformation.fid AS roadlinkinformation_fid,
	            roadlinkinformation.referencetoroadlink_href::text AS roadlink_fid
	           FROM roadlinkinformation) a;
	
	ALTER TABLE roadlinkinformation_roadlink
	  OWNER TO postgres;
	COMMENT ON VIEW roadlinkinformation_roadlink
	  IS 'Road link information cross reference view';

Then create a view of the links with height restrictions:

	CREATE OR REPLACE VIEW view_itn_heightrestriction AS 
	 SELECT rl.fid AS roadlink_fid,
	  array_to_string(rli.environmentqualifier_classification, ', '::text) AS environmentqualifier_classification,
	  array_to_string(rli.vehiclequalifier_maxheight,''::text) AS rl_height,
	  rl.wkb_geometry 
	  FROM roadlink rl,
	  roadlinkinformation rli,
	  roadlinkinformation_roadlink rlirl
	  WHERE rlirl.roadlink_fid = rl.fid
	  AND rli.fid = rlirl.roadlinkinformation_fid
	  AND rli.environmentqualifier_classification::text = '{"Bridge Over Road"}'::text
	  AND rli.vehiclequalifier_maxheight IS NOT NULL;
	ALTER TABLE view_itn_heightrestriction
	  OWNER TO postgres;
	COMMENT ON VIEW view_itn_heightrestriction
	  IS 'ITN bridge height restrictions';
	  
Finally, update the network table with the height restrictions:

	UPDATE itn_network SET rl_height = CAST(ht.rl_height AS numeric) 
	FROM view_itn_heightrestriction ht 
	WHERE itn_network.toid = ht.roadlink_fid;

References
----------
http://www.ordnancesurvey.co.uk/business-and-government/products/itn-layer.html

https://github.com/AstunTechnology/Loader

http://pgrouting.org/

http://docs.pgrouting.org/dev/doc/src/tutorial/analytics.html

http://www.archaeogeek.com/blog/2012/08/17/pgrouting-with-ordnance-survey-itn-data/

http://anitagraser.com/?s=pgrouting
