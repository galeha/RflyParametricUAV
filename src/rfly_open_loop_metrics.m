function result = rfly_open_loop_metrics(params, motorRadPerSecond)
%RFLY_OPEN_LOOP_METRICS Calculate actuator force and moment without Simulink.

omega = double(motorRadPerSecond(:));
if numel(omega) ~= 8 || any(~isfinite(omega))
    error("RflyParametricUAV:InvalidMotorSpeed", ...
        "motorRadPerSecond must contain eight finite values.");
end
omegaSquared = omega.^2;
result.force_body_N = params.force_gain * omegaSquared;
result.moment_body_Nm = params.moment_gain * omegaSquared;
end

