Feature: Custom Agentica steps

  Scenario Outline: Remember <number>
    Then scenario state is empty
    When I remember <number>
    Then the remembered number is <number>

    Examples:
      | number |
      | 7      |
      | -3     |

  Scenario: Doc String and Data Table
    When I submit a record:
      """json
      {"value":7}
      """
    Then the remembered number is 7
    And the table is valid:
      | label | value |
      | a\|b  | 7     |

  Scenario: Quoted capture
    Then the message is "hello \"world\""
