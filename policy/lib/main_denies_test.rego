package lib

import data.lib

test_current_and_future {
	lib.assert_empty(current_and_future_denies("bogus"))
	lib.assert_not_empty(current_and_future_denies("release")) with data.policy as mock_policies

	lib.assert_empty(current_and_future_warns("bogus"))
	lib.assert_not_empty(current_and_future_warns("release")) with data.policy as mock_policies
}

test_future_handling {
	future_denial := {"msg": "future", "effective_on": "2099-05-02T00:00:00Z"}
	current_denial := {"msg": "current", "effective_on": "1999-05-02T00:00:00Z"}
	lib.assert_equal(true, lib.in_future(future_denial))
	lib.assert_empty(lib.current_rules({future_denial}))
	lib.assert_empty(lib.future_rules({current_denial}))
	lib.assert_equal({future_denial}, lib.future_rules({future_denial}))
	lib.assert_equal({current_denial}, lib.current_rules({current_denial}))
	lib.assert_equal({current_denial}, lib.current_rules({current_denial, future_denial}))
	lib.assert_equal({future_denial}, lib.future_rules({future_denial, current_denial}))
}

test_include_exclude {
	# Rules excluded by wildcard
	lib.assert_empty(current_and_future_denies("release")) with data.config.policy.exclude as ["*"]
		with data.policy as mock_policies

	# Rules excluded by name
	lib.assert_empty(current_and_future_denies("release")) with data.config.policy.exclude as ["mock_package"]
		with data.policy as mock_policies

	# Rules included by name
	lib.assert_equal(1, count(current_and_future_denies("release"))) with data.config.policy.include as ["mock_package"]
		with data.policy as mock_policies

	# Rules excluded by wildcard
	lib.assert_empty(current_and_future_warns("release")) with data.config.policy.exclude as ["*"]
		with data.policy as mock_policies

	# Rules excluded by name
	lib.assert_empty(current_and_future_warns("release")) with data.config.policy.exclude as ["mock_package"]
		with data.policy as mock_policies

	# Rules included by name
	lib.assert_equal(1, count(current_and_future_warns("release"))) with data.config.policy.include as ["mock_package"]
		with data.policy as mock_policies
}

mock_policies := {"release": {"mock_package": {
	"deny": {{"code": "test_failure"}},
	"warn": {{"code": "test_warning"}},
}}}
