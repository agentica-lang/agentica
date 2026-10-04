Feature: JSON Lines replies

  Background:
    Given the Agentica program "../../../examples/json-lines.agc"

  Scenario: Reply before stdin closes
    When I send a line:
      """
      {"name":"Ana","score":80,"active":true}
      """
    Then I receive a JSON line within 5000 milliseconds:
      """
      {"passed":true,"name":"Ana"}
      """
    And stdin remains open
    When I close stdin
    Then the program exits with code 0 within 5000 milliseconds

  Scenario: Recover after an invalid record
    When I send the line "bad JSON"
    Then I receive a JSON line within 5000 milliseconds:
      """
      {"error":"invalid record"}
      """
    When I send a line:
      """
      {"name":"Luis","score":40,"active":true}
      """
    Then I receive a JSON line within 5000 milliseconds:
      """
      {"name":"Luis","passed":false}
      """
    When I close stdin
    Then the program exits with code 0 within 5000 milliseconds
