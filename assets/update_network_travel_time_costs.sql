-- adjust speeds as you see fit
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

-- update times with high reverse costs
UPDATE itn_network SET
cost_time = CASE
    WHEN one_way='TF' THEN 10000.0
    ELSE cost_len/1000.0/rl_speed::numeric*3600.0
    END,
rcost_time = CASE
    WHEN one_way='FT' THEN 10000.0
    ELSE cost_len/1000.0/rl_speed::numeric*3600.0
    END;
