#!/usr/bin/env julia

# Main test runner for BlaqueBaux framework
# Run all module tests + integration + stress tests

using Test

@info "="^70
@info "BLAQUE BAUX GAMMA-ARMA FRAMEWORK - COMPLETE TEST SUITE"
@info "="^70

# Track overall results
all_passed = true
module_results = Dict{String, Bool}()

# Helper to run a module's tests
function run_module_tests(module_name::String, test_file::String)
    @info ""
    @info "Running $module_name..."
    @info "-"^50

    try
        include(test_file)
        module_results[module_name] = true
        @info "✓ $module_name PASSED"
    catch e
        module_results[module_name] = false
        all_passed = false
        @error "✗ $module_name FAILED" exception=e
    end
end

# Unit Tests
@info ""
@info "UNIT TESTS"
@info "-"^50

run_module_tests("Module 1: Data Ingestion", "test_module_1.jl")
run_module_tests("Module 2: Signal Smoothing", "test_module_2.jl")
run_module_tests("Module 3: PCA Compression", "test_module_3.jl")
run_module_tests("Module 4: ARMA + GARCH", "test_module_4.jl")
run_module_tests("Module 5: DPM", "test_module_5.jl")
run_module_tests("Module 6: Cascade Interface", "test_module_6.jl")
run_module_tests("Module 7: Execution Layer", "test_module_7.jl")
run_module_tests("Module 8: Governance", "test_module_8.jl")
run_module_tests("Module 13: Portfolio Spine (Path-B strategy)", "test_spine.jl")
run_module_tests("Equity Panel (spine data adapter)", "test_equity_panel.jl")
run_module_tests("Execution Controller (governed order path)", "test_execution_controller.jl")
run_module_tests("Live Execution Integration (venue+ledger+audit)", "test_live_integration.jl")

# Integration Tests
@info ""
@info "INTEGRATION TESTS"
@info "-"^50

run_module_tests("End-to-End Integration", "test_integration.jl")

# Stress Tests
@info ""
@info "STRESS TESTS"
@info "-"^50

run_module_tests("Stress & Edge Cases", "test_stress.jl")

# Summary
@info ""
@info "="^70
@info "FINAL SUMMARY"
@info "="^70

passed_count = count(values(module_results))
total_count = length(module_results)

for (name, passed) in module_results
    status = passed ? "✓ PASS" : "✗ FAIL"
    @info "  $status - $name"
end

@info ""
@info "Total: $passed_count/$total_count test suites passed"

if all_passed
    @info ""
    @info "🎉 ALL TESTS PASSED - Framework production-ready"
else
    @info ""
    @warn "⚠️  SOME TESTS FAILED - Review required before deployment"
end

@info "="^70
