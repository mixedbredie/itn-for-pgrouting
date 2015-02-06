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
