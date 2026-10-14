extends Resource
## Editable fictional balancing constants, independent of cockpit art and radar.
## This resource defines game pacing, not real aircraft or weapons performance.
@export_group("Flight")
@export_range(10.0, 180.0) var cruise_speed := 62.0
@export_range(1.0, 60.0) var turn_rate_degrees := 12.0
@export_range(1.0, 300.0) var climb_rate := 75.0
@export_range(10.0, 250.0) var waypoint_radius := 85.0
@export_range(100.0, 4000.0) var fuel_duration := 700.0
@export var flight_boundary := 4200.0
@export_group("Fictional mission triggers")
@export var release_radius := 240.0
@export var egress_radius := 350.0
@export_group("Placeholder stores")
@export var initial_arm_count := 2
@export var initial_countermeasures := 4
@export var arm_delay := 6.5
@export var countermeasure_duration := 8.0
@export var countermeasure_reduction := 0.23
@export_group("Abstract threat meter")
@export var danger_radius := 1100.0
@export var danger_growth := 0.12
@export var danger_decay := 0.012
@export var damage_per_hit := 0.28
@export var warning_interval := 12.0
