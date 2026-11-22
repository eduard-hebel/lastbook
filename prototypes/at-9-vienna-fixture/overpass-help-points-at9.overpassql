[out:json][timeout:60];
(
  node["amenity"~"^(pharmacy|fire_station|police|hospital|drinking_water)$"](48.1179,16.1818,48.3227,16.5775);
  way["amenity"~"^(pharmacy|fire_station|police|hospital|drinking_water)$"](48.1179,16.1818,48.3227,16.5775);
  node["emergency"="defibrillator"](48.1179,16.1818,48.3227,16.5775);
);
out center tags;
