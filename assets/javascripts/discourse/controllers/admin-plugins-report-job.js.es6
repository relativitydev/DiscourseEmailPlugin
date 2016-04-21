export default Ember.Controller.extend({
    actions: {
        forceSendNow() {
            Discourse.ajax("/admin/plugins/report-job/trigger", {
               type: "PUT",
               data: {}
            });
        }
    }
});