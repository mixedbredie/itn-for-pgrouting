-- View: view_itn_bridges

-- DROP VIEW view_itn_bridges;

CREATE OR REPLACE VIEW view_itn_bridges AS 
 SELECT gs.roadname,
    (st_dump(st_linemerge(st_union(gs.wkb_geometry)))).geom AS wkb_geometry
 FROM view_itn_gradeseparation gs
 GROUP BY gs.roadname;

ALTER TABLE view_itn_bridges
  OWNER TO postgres;
