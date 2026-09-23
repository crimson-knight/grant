require "../../spec_helper"
require "./persistence_regression_models"

Spec.before_suite do
  T6PersistenceRecord.migrator.drop_and_create
  T6ReadonlyRecord.migrator.drop_and_create
  T6HaltedRecord.migrator.drop_and_create
  T6CommitFailureRecord.migrator.drop_and_create
  T6TouchRecord.migrator.drop_and_create
  T6DeleteRecord.migrator.drop_and_create
end
