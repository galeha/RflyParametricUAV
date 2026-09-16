function coeff = rfly_actuator_coefficients(actuator)
%RFLY_ACTUATOR_COEFFICIENTS Return canonical quadratic propulsion data.

directFields = {"max_speed_rad_s", "thrust_coeff_N_s2", ...
    "torque_coeff_Nm_s2"};
hasDirect = all(cellfun(@(name) isfield(actuator, name), directFields));
hasAnyDirect = any(cellfun(@(name) isfield(actuator, name), directFields));
hasTable = isfield(actuator, "static_table");

if hasAnyDirect && ~hasDirect
    error("RflyParametricUAV:IncompletePropulsionData", ...
        "Direct propulsion data requires max speed, thrust coefficient, and torque coefficient.");
end
if hasDirect == hasTable
    error("RflyParametricUAV:AmbiguousPropulsionData", ...
        "Provide exactly one of direct coefficients or static_table.");
end

if hasDirect
    coeff.max_speed_rad_s = double(actuator.max_speed_rad_s);
    coeff.thrust_coeff_N_s2 = double(actuator.thrust_coeff_N_s2);
    coeff.torque_coeff_Nm_s2 = double(actuator.torque_coeff_Nm_s2);
    coeff.source = "direct";
    return
end

tableData = actuator.static_table;
required = {"rpm", "thrust_N", "torque_Nm"};
if ~all(cellfun(@(name) isfield(tableData, name), required))
    error("RflyParametricUAV:IncompleteStaticTable", ...
        "static_table requires rpm, thrust_N, and torque_Nm.");
end

rpm = double(tableData.rpm(:));
thrust = double(tableData.thrust_N(:));
torque = double(tableData.torque_Nm(:));
if numel(rpm) < 2 || numel(rpm) ~= numel(thrust) || numel(rpm) ~= numel(torque)
    error("RflyParametricUAV:InvalidStaticTable", ...
        "Static-table vectors must have the same length and at least two samples.");
end
if any(~isfinite([rpm; thrust; torque])) || any(rpm <= 0) || ...
        any(thrust < 0) || any(torque < 0)
    error("RflyParametricUAV:InvalidStaticTable", ...
        "Static-table values must be finite; RPM positive; thrust and torque nonnegative.");
end

omegaSquared = (rpm * (2*pi/60)).^2;
denominator = omegaSquared' * omegaSquared;
coeff.max_speed_rad_s = max(rpm) * (2*pi/60);
coeff.thrust_coeff_N_s2 = (omegaSquared' * thrust) / denominator;
coeff.torque_coeff_Nm_s2 = (omegaSquared' * torque) / denominator;
coeff.source = "static_table_fit";
end

