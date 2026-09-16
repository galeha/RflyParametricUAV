function params = rfly_profile_to_model_params(cfg)
%RFLY_PROFILE_TO_MODEL_PARAMS Convert validated JSON data to fixed arrays.

maxActuators = 8;
activeCount = numel(cfg.actuators);
params.active_count = activeCount;
params.mass_kg = double(cfg.airframe.mass_kg);
params.inertia_kg_m2 = double(cfg.airframe.inertia_kg_m2);
params.cog_b_m = double(cfg.airframe.cog_b_m(:));
params.motor_command_min = zeros(1, maxActuators);
params.motor_command_span = ones(1, maxActuators);
params.motor_omega_max_rad_s = zeros(1, maxActuators);
params.motor_inverse_tau = ones(1, maxActuators);
params.initial_motor_rad_s = zeros(1, maxActuators);
params.force_gain = zeros(3, maxActuators);
params.moment_gain = zeros(3, maxActuators);

for index = 1:activeCount
    actuator = cfg.actuators(index);
    coeff = rfly_actuator_coefficients(actuator);
    axisB = double(actuator.thrust_axis_b(:));
    positionB = double(actuator.position_b_m(:)) - params.cog_b_m;
    forceColumn = axisB * coeff.thrust_coeff_N_s2;
    reactionColumn = double(actuator.reaction_torque_sign) * ...
        coeff.torque_coeff_Nm_s2 * axisB;

    params.motor_command_min(index) = double(actuator.command_min);
    params.motor_command_span(index) = double(actuator.command_max - actuator.command_min);
    params.motor_omega_max_rad_s(index) = coeff.max_speed_rad_s;
    params.motor_inverse_tau(index) = 1 / double(actuator.time_constant_s);
    params.force_gain(:, index) = forceColumn;
    params.moment_gain(:, index) = cross(positionB, forceColumn) + reactionColumn;
end

params.drag_coefficient = double(cfg.aero.drag_coefficient);
params.angular_damping = double(cfg.aero.angular_damping(:)).';
params.characteristic_length_m = double(cfg.aero.characteristic_length_m);
end

