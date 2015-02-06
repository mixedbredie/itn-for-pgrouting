UPDATE roadlink SET roadname = 
	(
	SELECT DISTINCT array_to_string(c.roadname,', ') AS roadname 
	FROM roadlink a 
	INNER JOIN road_roadlink b ON b.roadlink_fid = a.fid
	INNER JOIN road c ON c.fid = b.road_fid
	WHERE a.fid = roadlink.fid 
	AND c.descriptivegroup = 'Named Road'
	);
