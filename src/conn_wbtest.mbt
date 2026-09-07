// Copyright 2026 conglinyizhi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
test "session bus address uses unix path" {
  assert_eq(
    dbus_path_from_address("unix:path=/run/user/1001/bus"),
    Some("/run/user/1001/bus"),
  )
}

///|
test "session bus address decodes percent-encoded path" {
  assert_eq(
    dbus_path_from_address("unix:path=%2Frun%2Fuser%2F1001%2Fmy%20bus"),
    Some("/run/user/1001/my bus"),
  )
}

///|
test "session bus address accepts extra options" {
  assert_eq(
    dbus_path_from_address("unix:path=/run/user/1001/bus,guid=abc"),
    Some("/run/user/1001/bus"),
  )
}

///|
test "session bus address selects unix path from candidates" {
  assert_eq(
    dbus_path_from_address("tcp:host=127.0.0.1,port=1234;unix:path=/tmp/bus"),
    Some("/tmp/bus"),
  )
}

///|
test "session bus address rejects unsupported or malformed addresses" {
  assert_true(dbus_path_from_address("tcp:host=127.0.0.1,port=1234") is None)
  assert_true(dbus_path_from_address("unix:abstract=some-bus") is None)
  assert_true(dbus_path_from_address("unix:path=") is None)
}
