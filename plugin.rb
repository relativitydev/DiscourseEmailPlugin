# name: report-job
# about: Weekly email report for various metrics
# version: 0.0.1
# authors: Garrett Scholtes
# url: https://github.com/kCura/DiscourseEmailPlugin

enabled_site_setting :weekly_email_report_enabled

PATH = File.dirname(path)

after_initialize do

    require_dependency 'email/sender'
    require_dependency 'email/message_builder'
    
    if SiteSetting.weekly_email_report_interval < 1
        warn "WARNING: weekly_email_report_interval setting is less than 1 day"
    end
    
    module ::WeeklyJobHelpers       
        def self.report_time
            items = SiteSetting.weekly_email_report_time_of_day.split(":")
            if items.size == 2
                hours = items.first.to_i
                minutes = items.last.to_i
                if (0...24).include? hours and (0...60).include? minutes 
                else
                    warn "WARNING: weekly_email_report_time_of_day has invalid format"
                    return default_report_time
                end
            else
                warn "WARNING: weekly_email_report_time_of_day has invalid format"
                return default_report_time
            end
            return hours.hours + minutes.minutes
        end
        
        def self.default_report_time
            items = SiteSetting.defaults[:weekly_email_report_time_of_day].split(":")
            hours = items.first.to_i
            minutes = items.last.to_i
            return hours.hours + minutes.minutes
        end
        
        def self.weekday
            case SiteSetting.weekly_email_report_day_of_week.downcase.strip
            when "sunday"
                0
            when "monday"
                1
            when "tuesday"
                2
            when "wednesday"
                3
            when "thursday"
                4
            when "friday"
                5
            when "saturday"
                6
            else
                warn "WARNING: invalid weekday for weekly_email_report_day_of_week"
                0
            end
        end
        
        def self.is_correct_weekday
            Date.today.wday == weekday
        end    
    end
    
    class ::WeeklyReportMailer < ::ActionMailer::Base
        default from: SiteSetting.notification_email
    
        def send_report_to(recipient, metrics, time)
            @metrics = metrics
            @hostroot = "#{SiteSetting.weekly_email_report_domain}"
            mail(to: recipient, subject: weekly_subject(time)) { |f|
                f.text { render file: File.join(view_path, "send_report_to.text.erb") }
                f.html { render file: File.join(view_path, "send_report_to.html.erb") }
            }
        end
        
        private
        
        def weekly_subject(time)
            "[#{time.to_date}] #{SiteSetting.weekly_email_report_subject}"
        end
        
        def view_path
            # Hack. Rails will not look in the plugin's app/views directory
            # for views.  This is a workaround.
            File.join(PATH, "app", "views", "weekly_report_mailer")
        end
    end
    
    class ::Jobs::MetricsReportJob < Jobs::Scheduled
        daily at: ::WeeklyJobHelpers.report_time
        
        include ActionView::Helpers::DateHelper
        
        def execute(args)
            if (SiteSetting.weekly_email_report_enabled? and ::WeeklyJobHelpers.is_correct_weekday) or args[:force]
                @latest_midnight = Time.now.midnight
                @interval = SiteSetting.weekly_email_report_interval.days
                
                topic_list = new_topics
                metrics = {
                    new_topics: topic_list,
                    no_response: no_response(topic_list),
                    average_response_time: average_response_time(topic_list),
                    solved: solved(topic_list),
                    top_posters: top_posters(SiteSetting.weekly_email_report_top_user_count),
                    top_creators: top_topic_creators(SiteSetting.weekly_email_report_top_user_count),
                    table: gather_category_statistics(topic_list)
                }
                
                recipients = SiteSetting.weekly_email_report_recipients.split(",")
                recipients.map! { |recipient|
                    recipient.strip
                }
                
                recipients.each { |recipient|
                    WeeklyReportMailer.send_report_to(recipient, metrics, @latest_midnight).deliver_now
                }
            end
        end
        
        private
        
        def new_topics
            Topic.where(created_at: (@latest_midnight - @interval)..@latest_midnight, subtype: nil)
        end
        
        def no_response(topics)
            topics.where(posts_count: (0..1))
        end
        
        def average_response_time(tops, category=nil)
            if category
                topics = tops.where("posts_count > 1").where(category: category)
            else
                topics = tops.where("posts_count > 1")
            end
            avg = 0
            topics_size = topics.size
            if topics_size > 0
                avg = topics.inject(0) { |acc, topic|
                    # Second post is the first reply (first post is the topic itself -- not a reply)
                    post_time = Post.where(topic: topic).order(:created_at).limit(2)[1].created_at.to_i
                    topic_time = topic.created_at.to_i
                    acc + post_time - topic_time
                } / topics_size
            end 
            distance_of_time_in_words(avg)
        end
        
        def solved(topics)
            TopicCustomField.where(created_at: (@latest_midnight - @interval)..@latest_midnight)
                .where(name: "accepted_answer_post_id")
                .where("topic_id IN (?)", topics.select(:id))
                .size
        end
        
        def top_posters(limit)
            posts = Post.where(created_at: (@latest_midnight - @interval)..@latest_midnight)
            posts.map { |p|
                p.username
            }.each_with_object(Hash.new(0)) { |username, occurrences|
                occurrences[username] += 1
            }.sort_by { |username, count|
                -count
            }.map { |username, count|
                {username: username, posts: count}
            }.select { |user|
                user[:username] != "system"
            }[0,limit]
        end
        
        def top_topic_creators(limit)
            topics = Topic.where(created_at: (@latest_midnight - @interval)..@latest_midnight)
            topics.map { |t|
                User.find(t.user_id).username
            }.each_with_object(Hash.new(0)) { |username, occurrences|
                occurrences[username] += 1
            }.sort_by { |username, count|
                -count
            }.map { |username, count|
                {username: username, topics: count}
            }.select { |user|
                user[:username] != "system"
            }[0,limit]
        end
        
        def gather_category_statistics(tops)
            table = []
            Category.select(:id, :name, :slug, :color, :parent_category_id).each { |category|
                parent = nil
                if not category.parent_category_id.nil?
                    parent = Category.find(category.parent_category_id)
                end
                samples = tops.where(category: category)
                response_percent = ""
                percent_compliant = ""
                art = ""
                if samples.length > 0
                    art = average_response_time(tops, category)
                    selected = samples.where("posts_count > 1")
                    response_percent = sprintf("%0.1f %", 100*selected.length.to_f / samples.length)
                    compliant = selected.select { |topic|
                        # Second post is the first reply (first post is the topic itself -- not a reply)
                        post_time = Post.where(topic: topic).order(:created_at).limit(2)[1].created_at.to_i
                        topic_time = topic.created_at.to_i
                        post_time - topic_time < 60 * SiteSetting.weekly_email_report_compliance
                    }
                    percent_compliant = compliant.length.to_f / samples.length
                    percent_compliant = sprintf("%0.1f %", 100*percent_compliant)
                end
                table << {
                    category: category,
                    avg_response_time: art,
                    percent_response_compliant: percent_compliant,
                    response_percent: response_percent,
                    sample_size: samples.length,
                    color: category.color,
                    parent: parent
                }
            }
            # Sorts by parent categories, and then by subcategories under each parent
            table.sort_by { |row|
                name = ""
                if row[:parent]
                    name = row[:parent].name.downcase
                end
                name + row[:category].name.downcase
            }
        end
        
    end
    
    # ---------- Send an email immediately when the plugin loads ----------------
    # ---------- otherwise we might have to wait a week to get a report ------------
    ::Jobs::MetricsReportJob.new.execute({force: true})
    # ---------------------------------------------------------------------------
    
    module ::DiscourseReportJob
        class Engine < ::Rails::Engine
            isolate_namespace DiscourseReportJob
        end
    end
    
    require_dependency 'application_controller'
    class DiscourseReportJob::ReporterController < ::ApplicationController        
        def send(*args)
            ::Jobs::MetricsReportJob.new.execute({force: true})
        end
    end

    DiscourseReportJob::Engine.routes.draw do
        put 'trigger' => 'reporter#send'
    end


    add_admin_route 'report_job.title', 'report-job'
        
    Discourse::Application.routes.append do
        mount ::DiscourseReportJob::Engine, at: '/admin/plugins/report-job', constraints: StaffConstraint.new
    end
    
end