-- road link start and end coordinates
UPDATE itn_network 
SET x1 = st_x(st_startpoint(geometry)),
  y1 = st_y(st_startpoint(geometry)),
  x2 = st_x(st_endpoint(geometry)),
  y2 = st_y(st_endpoint(geometry));

-- length costs
UPDATE itn_network
SET cost_len = ST_Length(geometry),
  rcost_len = ST_Length(geometry);

-- one way costs
UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute < 500;
UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute < 500;
UPDATE itn_network SET cost_len = ST_Length(geometry) WHERE rl_attribute > 500 and rl_attribute < 1000;
UPDATE itn_network SET rcost_len = cost_len*1000 WHERE rl_attribute > 500 and rl_attribute < 1000;
UPDATE itn_network SET cost_len = ST_Length(geometry)*1000 WHERE rl_attribute > 1000;
UPDATE itn_network SET rcost_len = ST_Length(geometry) WHERE rl_attribute > 1000;

-- one way attributes
UPDATE itn_network SET one_way = 'B' WHERE rl_attribute < 500;
UPDATE itn_network SET one_way = 'TF' WHERE rl_attribute > 500 AND rl_attribute < 1000;
UPDATE itn_network SET one_way = 'FT' WHERE rl_attribute > 1000;
