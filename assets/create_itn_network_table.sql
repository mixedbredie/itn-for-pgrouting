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
