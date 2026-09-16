classdef rflyProfileTest < matlab.unittest.TestCase

    methods (TestClassSetup)
        function addProjectSource(testCase)
            projectRoot = fileparts(fileparts(mfilename("fullpath")));
            sourceFolder = fullfile(projectRoot, "src");
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture(sourceFolder));
        end
    end

    methods (Test, TestTags = {'Unit'})
        function testQuadProfileLoads(testCase)
            profilePath = fullfile(rflyProfileTest.projectRoot(), "configs", "quad_x.json");
            [cfg, params, report] = rfly_load_profile(profilePath);

            testCase.verifyTrue(report.is_valid);
            testCase.verifyEqual(string(cfg.variant), "quad_x");
            testCase.verifyEqual(params.active_count, 4);
            testCase.verifySize(params.force_gain, [3 8]);
            testCase.verifySize(params.moment_gain, [3 8]);
            testCase.verifyEqual(string(cfg.visual.install_mode), "builtin");
        end

        function testTailPusherProfileLoads(testCase)
            profilePath = fullfile(rflyProfileTest.projectRoot(), "configs", "tailpusher_36kg.json");
            [cfg, params, report] = rfly_load_profile(profilePath);

            testCase.verifyTrue(report.is_valid);
            testCase.verifyEqual(string(cfg.variant), "quad_x_tailpusher");
            testCase.verifyEqual(params.active_count, 5);
            testCase.verifyNotEmpty(report.warnings);
            testCase.verifyEqual(string(cfg.visual.install_mode), "reuse_existing");
            testCase.verifyEqual(string(cfg.visual.existing_xml_name), "TailPusher_F450.xml");
        end

        function testQuadEqualSpeedCancelsMoments(testCase)
            profilePath = fullfile(rflyProfileTest.projectRoot(), "configs", "quad_x.json");
            [~, params] = rfly_load_profile(profilePath);
            omega = [500 500 500 500 0 0 0 0];
            result = rfly_open_loop_metrics(params, omega);

            testCase.verifyEqual(result.moment_body_Nm, zeros(3, 1), AbsTol=1e-12);
            testCase.verifyLessThan(result.force_body_N(3), 0);
        end

        function testTailPusherForceAndMomentSigns(testCase)
            profilePath = fullfile(rflyProfileTest.projectRoot(), "configs", "tailpusher_36kg.json");
            [~, params] = rfly_load_profile(profilePath);
            omega = [0 0 0 0 100 0 0 0];
            result = rfly_open_loop_metrics(params, omega);

            testCase.verifyGreaterThan(result.force_body_N(1), 0);
            testCase.verifyLessThan(result.moment_body_Nm(1), 0);
            testCase.verifyLessThan(result.moment_body_Nm(2), 0);
            testCase.verifyEqual(result.force_body_N(2:3), zeros(2, 1), AbsTol=1e-12);
        end

        function testNegativeMassIsRejected(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            cfg = rflyProfileTest.readProfile("quad_x.json");
            cfg.airframe.mass_kg = -1;
            invalidPath = fullfile(fixture.Folder, "invalid_mass.json");
            rflyProfileTest.writeJson(invalidPath, cfg);

            testCase.verifyError(@() rfly_load_profile(invalidPath), ...
                "RflyParametricUAV:InvalidProfile");
        end

        function testNonUnitAxisIsRejected(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            cfg = rflyProfileTest.readProfile("quad_x.json");
            cfg.actuators(1).thrust_axis_b = [0 0 -2];
            invalidPath = fullfile(fixture.Folder, "invalid_axis.json");
            rflyProfileTest.writeJson(invalidPath, cfg);

            testCase.verifyError(@() rfly_load_profile(invalidPath), ...
                "RflyParametricUAV:InvalidProfile");
        end

        function testInsufficientThrustIsRejected(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            cfg = rflyProfileTest.readProfile("quad_x.json");
            cfg.airframe.mass_kg = 1e6;
            invalidPath = fullfile(fixture.Folder, "invalid_thrust.json");
            rflyProfileTest.writeJson(invalidPath, cfg);

            testCase.verifyError(@() rfly_load_profile(invalidPath), ...
                "RflyParametricUAV:InvalidProfile");
        end

        function testInvalidVisualInstallModeIsRejected(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            cfg = rflyProfileTest.readProfile("quad_x.json");
            cfg.visual.install_mode = "overwrite";
            invalidPath = fullfile(fixture.Folder, "invalid_visual_mode.json");
            rflyProfileTest.writeJson(invalidPath, cfg);

            testCase.verifyError(@() rfly_load_profile(invalidPath), ...
                "RflyParametricUAV:InvalidProfile");
        end

        function testStaticTableFit(testCase)
            actuator.static_table.rpm = [1000 2000 3000];
            omega = actuator.static_table.rpm * 2*pi/60;
            actuator.static_table.thrust_N = 2e-4 * omega.^2;
            actuator.static_table.torque_Nm = 3e-6 * omega.^2;
            coeff = rfly_actuator_coefficients(actuator);

            testCase.verifyEqual(coeff.thrust_coeff_N_s2, 2e-4, AbsTol=1e-14);
            testCase.verifyEqual(coeff.torque_coeff_Nm_s2, 3e-6, AbsTol=1e-16);
            testCase.verifyEqual(coeff.max_speed_rad_s, omega(end), AbsTol=1e-12);
        end

        function testRfly3dXmlGeneration(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            cfg = rflyProfileTest.readProfile("tailpusher_36kg.json");
            outputPath = fullfile(fixture.Folder, "tailpusher.xml");
            rfly_write_3d_xml(cfg, outputPath);
            xmlText = fileread(outputPath);

            testCase.verifySubstring(xmlText, "<ClassID>4510</ClassID>");
            testCase.verifyEqual(count(xmlText, "<Actuator>"), 5);
            testCase.verifySubstring(xmlText, "<x>-70</x><y>0</y><z>4.5</z>");
        end
    end

    methods (Static, Access = private)
        function root = projectRoot()
            root = fileparts(fileparts(mfilename("fullpath")));
        end

        function cfg = readProfile(name)
            path = fullfile(rflyProfileTest.projectRoot(), "configs", name);
            cfg = jsondecode(fileread(path));
        end

        function writeJson(path, cfg)
            fileId = fopen(path, "w", "n", "UTF-8");
            cleanup = onCleanup(@() fclose(fileId)); %#ok<NASGU>
            fprintf(fileId, "%s", jsonencode(cfg, PrettyPrint=true));
        end
    end
end
