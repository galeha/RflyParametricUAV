function report = rfly_validate_profile(cfg)
%RFLY_VALIDATE_PROFILE Validate a v1 RflyParametricUAV JSON structure.

errors = strings(0, 1);
warnings = strings(0, 1);

requiredTop = {"schema_version", "profile_id", "variant", "airframe", ...
    "actuators", "aero", "environment", "initial", "visual", "px4", ...
    "simulation"};
missingTop = requiredTop(~cellfun(@(name) isfield(cfg, name), requiredTop));
if ~isempty(missingTop)
    errors(end+1, 1) = "Missing top-level fields: " + strjoin(missingTop, ", ");
    report = makeReport(errors, warnings);
    return
end

if ~isequal(double(cfg.schema_version), 1)
    errors(end+1, 1) = "schema_version must be 1.";
end
if ~(ischar(cfg.profile_id) || (isstring(cfg.profile_id) && isscalar(cfg.profile_id))) || ...
        isempty(regexp(char(cfg.profile_id), '^[A-Za-z][A-Za-z0-9_-]*$', 'once'))
    errors(end+1, 1) = "profile_id must start with a letter and contain only letters, digits, underscore, or hyphen.";
end

variant = string(cfg.variant);
if ~any(variant == ["quad_x", "quad_x_tailpusher"])
    errors(end+1, 1) = "variant must be quad_x or quad_x_tailpusher.";
end

airframeFields = {"mass_kg", "inertia_kg_m2", "cog_b_m"};
if ~all(cellfun(@(name) isfield(cfg.airframe, name), airframeFields))
    errors(end+1, 1) = "airframe requires mass_kg, inertia_kg_m2, and cog_b_m.";
else
    mass = double(cfg.airframe.mass_kg);
    inertia = double(cfg.airframe.inertia_kg_m2);
    if ~isFinitePositiveScalar(mass)
        errors(end+1, 1) = "airframe.mass_kg must be finite and positive.";
    end
    if ~isequal(size(inertia), [3 3]) || any(~isfinite(inertia), "all")
        errors(end+1, 1) = "airframe.inertia_kg_m2 must be a finite 3-by-3 matrix.";
    elseif norm(inertia - inertia.', "fro") > 1e-9
        errors(end+1, 1) = "airframe.inertia_kg_m2 must be symmetric.";
    elseif any(eig((inertia + inertia.')/2) <= 0)
        errors(end+1, 1) = "airframe.inertia_kg_m2 must be positive definite.";
    end
    if ~isFiniteVector(cfg.airframe.cog_b_m, 3)
        errors(end+1, 1) = "airframe.cog_b_m must contain three finite values.";
    end
end

actuators = cfg.actuators;
expectedCount = 4 + double(variant == "quad_x_tailpusher");
if ~isstruct(actuators) || numel(actuators) ~= expectedCount
    errors(end+1, 1) = sprintf("variant %s requires exactly %d actuators.", variant, expectedCount);
else
    channels = nan(1, expectedCount);
    maxVerticalThrust = 0;
    requiredActuator = {"channel", "position_b_m", "thrust_axis_b", ...
        "reaction_torque_sign", "time_constant_s", "command_min", ...
        "command_max", "validation_status"};
    for index = 1:expectedCount
        actuator = actuators(index);
        missing = requiredActuator(~cellfun(@(name) isfield(actuator, name), requiredActuator));
        if ~isempty(missing)
            errors(end+1, 1) = sprintf("Actuator %d is missing: %s.", index, strjoin(missing, ", "));
            continue
        end
        channels(index) = double(actuator.channel);
        if ~isFiniteVector(actuator.position_b_m, 3)
            errors(end+1, 1) = sprintf("Actuator %d position_b_m must contain three finite values.", index);
        end
        if ~isFiniteVector(actuator.thrust_axis_b, 3)
            errors(end+1, 1) = sprintf("Actuator %d thrust_axis_b must contain three finite values.", index);
        elseif abs(norm(double(actuator.thrust_axis_b(:))) - 1) > 1e-6
            errors(end+1, 1) = sprintf("Actuator %d thrust_axis_b must be a unit vector.", index);
        end
        if ~ismember(double(actuator.reaction_torque_sign), [-1 1])
            errors(end+1, 1) = sprintf("Actuator %d reaction_torque_sign must be -1 or 1.", index);
        end
        if ~isFinitePositiveScalar(double(actuator.time_constant_s))
            errors(end+1, 1) = sprintf("Actuator %d time_constant_s must be positive.", index);
        end
        commandMin = double(actuator.command_min);
        commandMax = double(actuator.command_max);
        if ~isfinite(commandMin) || ~isfinite(commandMax) || commandMin < 0 || ...
                commandMax > 1 || commandMin >= commandMax
            errors(end+1, 1) = sprintf("Actuator %d command range must satisfy 0 <= min < max <= 1.", index);
        end
        try
            coeff = rfly_actuator_coefficients(actuator);
            if ~isFinitePositiveScalar(coeff.max_speed_rad_s) || ...
                    ~isFinitePositiveScalar(coeff.thrust_coeff_N_s2) || ...
                    ~isfinite(coeff.torque_coeff_Nm_s2) || coeff.torque_coeff_Nm_s2 < 0
                errors(end+1, 1) = sprintf("Actuator %d propulsion coefficients are out of range.", index);
            elseif isFiniteVector(actuator.thrust_axis_b, 3)
                axisB = double(actuator.thrust_axis_b(:));
                maxVerticalThrust = maxVerticalThrust + max(0, -axisB(3)) * ...
                    coeff.thrust_coeff_N_s2 * coeff.max_speed_rad_s^2;
            end
        catch exception
            errors(end+1, 1) = sprintf("Actuator %d: %s", index, exception.message);
        end
        if string(actuator.validation_status) ~= "measured"
            warnings(end+1, 1) = sprintf("Actuator %d parameters are marked '%s'.", ...
                index, string(actuator.validation_status));
        end
    end

    if any(~isfinite(channels)) || any(channels ~= round(channels)) || ...
            ~isequal(sort(channels), 1:expectedCount)
        errors(end+1, 1) = "Actuator channels must be unique and consecutive from 1.";
    end
    if expectedCount >= 4
        for index = 1:4
            if isFiniteVector(actuators(index).thrust_axis_b, 3) && ...
                    norm(double(actuators(index).thrust_axis_b(:)) - [0;0;-1]) > 1e-6
                errors(end+1, 1) = sprintf("Lift actuator %d must point along body -Z in v1.", index);
            end
        end
    end
    if variant == "quad_x_tailpusher" && isFiniteVector(actuators(5).thrust_axis_b, 3) && ...
            norm(double(actuators(5).thrust_axis_b(:)) - [1;0;0]) > 1e-6
        errors(end+1, 1) = "Tail-pusher actuator 5 must point along body +X in v1.";
    end

    if exist("mass", "var") && isFinitePositiveScalar(mass)
        weight = mass * 9.80665;
        if maxVerticalThrust <= weight
            errors(end+1, 1) = sprintf("Maximum vertical thrust %.3f N does not exceed weight %.3f N.", ...
                maxVerticalThrust, weight);
        else
            thrustToWeight = maxVerticalThrust / weight;
            hoverFraction = sqrt(weight / maxVerticalThrust);
            if thrustToWeight < 1.3
                warnings(end+1, 1) = sprintf("Vertical thrust-to-weight ratio is only %.3f.", thrustToWeight);
            end
            if hoverFraction < 0.25 || hoverFraction > 0.75
                warnings(end+1, 1) = sprintf("Estimated normalized hover fraction %.3f is outside 0.25 to 0.75.", hoverFraction);
            end
        end
    end
end

aeroFields = {"drag_coefficient", "angular_damping", "characteristic_length_m"};
if ~all(cellfun(@(name) isfield(cfg.aero, name), aeroFields))
    errors(end+1, 1) = "aero requires drag_coefficient, angular_damping, and characteristic_length_m.";
elseif ~isfinite(double(cfg.aero.drag_coefficient)) || double(cfg.aero.drag_coefficient) < 0 || ...
        ~isFiniteVector(cfg.aero.angular_damping, 3) || any(double(cfg.aero.angular_damping) < 0) || ...
        ~isFinitePositiveScalar(double(cfg.aero.characteristic_length_m))
    errors(end+1, 1) = "aero parameters must be finite and nonnegative; characteristic length must be positive.";
end

if ~isfield(cfg.visual, "class_id") || ~isFinitePositiveScalar(double(cfg.visual.class_id)) || ...
        double(cfg.visual.class_id) ~= round(double(cfg.visual.class_id))
    errors(end+1, 1) = "visual.class_id must be a positive integer.";
end
if ~isfield(cfg.visual, "install_mode")
    errors(end+1, 1) = "visual.install_mode is required.";
else
    visualInstallMode = string(cfg.visual.install_mode);
    if ~any(visualInstallMode == ["builtin", "reuse_existing", "generated"])
        errors(end+1, 1) = "visual.install_mode must be builtin, reuse_existing, or generated.";
    elseif visualInstallMode == "reuse_existing"
        if ~isfield(cfg.visual, "existing_xml_name") || ...
                isempty(regexp(char(string(cfg.visual.existing_xml_name)), ...
                '^[^\\/:*?"<>|]+\.xml$', 'once'))
            errors(end+1, 1) = "reuse_existing visual mode requires a safe existing_xml_name ending in .xml.";
        end
    end
end
if ~isfield(cfg.visual, "actuators") || numel(cfg.visual.actuators) ~= expectedCount
    errors(end+1, 1) = "visual.actuators must match the physical actuator count.";
end

px4Fields = {"source_key", "sitl_frame", "expected_output_channels"};
if ~all(cellfun(@(name) isfield(cfg.px4, name), px4Fields))
    errors(end+1, 1) = "px4 requires source_key, sitl_frame, and expected_output_channels.";
elseif exist("channels", "var") && ...
        ~isequal(double(cfg.px4.expected_output_channels(:)).', channels)
    errors(end+1, 1) = "px4.expected_output_channels must match actuator channel order.";
end

report = makeReport(errors, warnings);
end

function report = makeReport(errors, warnings)
report.is_valid = isempty(errors);
report.errors = cellstr(errors);
report.warnings = cellstr(warnings);
end

function result = isFinitePositiveScalar(value)
result = isnumeric(value) && isscalar(value) && isfinite(value) && value > 0;
end

function result = isFiniteVector(value, expectedLength)
result = isnumeric(value) && numel(value) == expectedLength && all(isfinite(double(value(:))));
end
