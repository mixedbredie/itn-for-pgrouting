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
