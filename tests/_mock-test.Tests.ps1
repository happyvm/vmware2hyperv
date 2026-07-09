Set-StrictMode -Version Latest

# Pester 6 requires commands to exist before mocking them.
# Define stub functions first, then override with Mock.

function Get-VDPortgroup { throw "Not mocked" }
function Get-VirtualPortGroup { throw "Not mocked" }
function Get-View { throw "Not mocked" }
function Get-Cluster { throw "Not mocked" }

Describe "Mock Test - with stub functions" {
    BeforeAll {
        Mock Get-VDPortgroup { return @() }
    }
    It "mock intercepts after stub" {
        $result = Get-VDPortgroup -Name "test"
        $result | Should -HaveCount 0
    }
}