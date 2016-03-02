# name: report-job
# about: Weekly email report for various metrics
# version: 0.0.1
# authors: Garrett Scholtes

enabled_site_setting :weekly_email_report_enabled

RECIPIENTS = [
    "mrobustelli@kcura.com",
    "gscholtes@kcura.com",
    "jsmits@kcura.com"
]

HOSTROOT = "http://localhost:4000"

PATH = File.dirname(path)

after_initialize do

    require_dependency 'email/sender'
    require_dependency 'email/message_builder'
    
    class ::WeeklyReportMailer < ::ActionMailer::Base
        default from: SiteSetting.notification_email
    
        def send_report_to(recipient, metrics)
            @metrics = metrics
            @hostroot = HOSTROOT
            mail(to: recipient, subject: weekly_subject) { |f|
                f.text { render file: File.join(view_path, "send_report_to.text.erb") }
                f.html { render file: File.join(view_path, "send_report_to.html.erb") }
            }
        end
        
        private
        
        def weekly_subject
            "[#{Date.today}] DevHelp metrics"
        end
        
        def view_path
            File.join(PATH, "app", "views", "weekly_report_mailer")
        end
    end
    
    class ::Jobs::WeeklyReportJob < Jobs::Scheduled
        every 30.seconds
        
        include ActionView::Helpers::DateHelper
        
        def execute(args)
            metrics = {}
            metrics[:new_topics] = new_topics
            metrics[:no_response] = no_response(metrics[:new_topics])
            metrics[:average_response_time] = average_response_time(metrics[:new_topics])
            metrics[:solved] = solved(metrics[:new_topics])
            metrics[:top_posters] = top_posters(4)
            
            RECIPIENTS.each { |recipient|
                WeeklyReportMailer.send_report_to(recipient, metrics).deliver_now
            }
        end
        
        private
        
        def new_topics
            Topic.where("current_timestamp - created_at < INTERVAL '1 week' and subtype is NULL")
        end
        
        def no_response(topics)
            topics.where("posts_count <= 1")
        end
        
        def average_response_time(tops)
            topics = tops.where("posts_count > 1")
            avg = 0
            if topics.size > 0
                avg = topics.inject(0) { |acc, topic|
                    post_time = Post.where(topic_id: topic.id).sort_by { |post|
                        post.created_at.to_i
                    }[1].created_at.to_i
                    topic_time = topic.created_at.to_i
                    acc + post_time - topic_time
                } / topics.size
            end 
            distance_of_time_in_words(avg)
        end
        
        def solved(topics)
            TopicCustomField.where("current_timestamp - created_at < INTERVAL '1 week'")
                .where(name: "accepted_answer_post_id")
                .where("topic_id IN (?)", topics.select(:id))
                .size
        end
        
        def top_posters(limit)
            posts = Post.where("current_timestamp - created_at < INTERVAL '1 week'")
            posts.map { |p|
                p.username
            }.each_with_object(Hash.new(0)){
                |m,h| h[m] += 1
            }.sort_by{
                |k,v| -v
            }.map {
                |k, v| k
            }[0,limit]
        end
    end
    
end


=begin
# List of new topics from the last week
Topic.where("current_timestamp - created_at < INTERVAL '1 week' and subtype is NULL")

# List of new topics without any replies from the last week
Topic.where("posts_count <= 1 and current_timestamp - created_at < INTERVAL '1 week'")
# Or alternatively
list_of_topics_from_the_last_week.where("posts_count <= 1")

# Get topic response times
# Perform average in Ruby, not in sql
lst = lotftlw.where("posts_count > 1")
avg = 0
if lst.size > 0
    avg = lst.inject(0) { |acc, topic|
        post_time = Post.where(topic_id: topic.id).sort_by { |post|
            post.created_at.to_i
        }[1].created_at.to_i
        topic_time = topic.created_at.to_i
        acc + post_time - topic_time
    } / lst.size
end 
avg # Gives time in seconds

# Get number of topics from the last week that were marked as solved
TopicCustomField.where("current_timestamp - created_at < INTERVAL '1 week'").where(name: "accepted_answer_post_id").where("topic_id IN (?)", lotftlw.select(:id)).size

# Get 4 most active users
posts = Post.where("current_timestamp - created_at < INTERVAL '1 week'")
posts.map { |p| p.username }.each_with_object(Hash.new(0)){ |m,h| h[m] += 1 }.sort_by{ |k,v| -v }.map { |k, v| k }[0,4]

# Scheduling a task
Date.today.next_week(:monday).in(6.00 * 3600) # Next monday @ 6:00 am

# Daisy chain schedule (possibly unreliable) if necessary:
    class WeeklyMailReport < ActiveJob::Base
        INTERVAL = 30.seconds
        
        def perform
            print "Hello #{rand}"
            
            self.class.perform_later(wait_until: Date.today.next_week(:monday))
        end
    end
    WeeklyMailReport.new.perform

# The code below successfully sends a test email programmatically.
# Had issues sending it from the console, but that might be something else.
message = TestMailer.send_test("pluginemailtest@example.com")
Email::Sender.new(message, :test_message).send

=end