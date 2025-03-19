# How to deploy your Django app on Linode VPS ☁️
- If you'd like to give Linode a try without spending your own money, I have a referral link ($60 credit) at the bottom of this page. 👇
- You can deploy a single app or multiple apps on the same VPS  


&nbsp;


## A few things to note before we start
- Avoid symbols in nomenclature
- Run ``` python manage.py runserver ``` to check for errors with the django application
- Also, bear in mind that my file strucutre is <YOUR_DIR>/<YOUR_PROJECT>/wsgi.py (Bear this in mind for gunicorn service file)
- When you run gunicorn, you should get a /var/www/django_app/<DJANGO_APP>.sock file - check that it exists
- ⚠️ If you have any .env files and they are not in the repo, it might cause an issue


&nbsp;


## Installing gunicorn and nginx
- Git clone your app into the /var/www/django_app/ directory
- Install requirements.txt of both projects in the same venv (not sure what the advantages or disadvantages are, need to look into it)
- Pip install gunicorn   
- Install nginx using this guide: https://www.linode.com/docs/guides/use-nginx-reverse-proxy/#install-nginx


&nbsp;


## Configure gunicorn service file 
- You need a gunicorn service file for each app at /etc/systemd/system/<app_name>_gunicorn.service
- The /var/www/django_app/<app_name>.sock file will be created on its own


&nbsp;


Gunicorn service file template (Copy it)
```
[Unit]
Description=Gunicorn instance to serve <app_name>
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=/var/www/django_app/<app_name>
ExecStart=/var/www/django_app/djangoenv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/var/www/django_app/<app_name>.sock proj.wsgi:application

[Install]
WantedBy=multi-user.target
```


&nbsp;


## Configure Nginx files
- Each application needs it own nginx config at /etc/nginx/sites-available/<app1_name> and /etc/nginx/sites-avialable/<app2_name>
```
server {
    listen 80;
    server_name <domain_name>;

    location / {
        include proxy_params;
        proxy_pass http://unix:/var/www/django_app/<app1_name>.sock;
    }
}
```
- You will still need an nginx config file, like a master file at /etc/nginx/conf.d/nginx.conf
```
include /etc/nginx/sites-enabled/*;
```


&nbsp;


## Enable and start gunicorn services
```
sudo systemctl start <app1_name>_gunicorn
sudo systemctl enable <app1_name>_gunicorn
sudo systemctl start <app2_name>_gunicorn
sudo systemctl enable <app2_name>_gunicorn
```


&nbsp;



## Enable, test and restart nginx sites
```
sudo ln -s /etc/nginx/sites-available/<app1_name> /etc/nginx/sites-enabled
sudo ln -s /etc/nginx/sites-available/<app2_name> /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx
```


&nbsp;



## Set up SSL for the domain
- Follow this guide to install certbot: https://www.linode.com/docs/guides/enabling-https-using-certbot-with-nginx-on-debian/
- But stop just before this command ``` sudo certbox --nginx ``` and do this instead
```
sudo certbot --nginx -d <domain_name1> -d www.<domain_name1> -d <domain_name2> -d www.<domain_name2>
```


&nbsp;


## Debug/Troubleshooting
- If there's an error, check the followings
- Check gunicorn services
```
sudo systemctl status <app1_name>_gunicorn
sudo systemctl status <app2_name>_gunicorn
```

- Check nginx log
```
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/www/django_app/<app1_name>/gunicorn.log
sudo tail -f /var/www/django_app/<app2_name>/gunicorn.log
```

- Test gunicorn manually
```
cd /var/www/django_app/<app1_name>
source /var/www/django_app/djangoenv/bin/activate
gunicorn --access-logfile - --workers 3 --bind unix:/var/www/django_app/<app1_name>.sock problem-bank.wsgi:application
```


&nbsp;


## If you've made changes to the service files, do this
```
sudo systemctl daemon-reload
sudo systemctl start problem-bank_gunicorn
sudo systemctl enable problem-bank_gunicorn
sudo systemctl start phone-repair_gunicorn
sudo systemctl enable phone-repair_gunicorn
```


&nbsp;


## If you've updated content
git pull the content into your project folder first   
```
sudo systemctl restart phone-repair_gunicorn
sudo systemctl restart problem-bank_gunicorn
sudo systemctl reload nginx
```


## If you've removed a website, deleted the .sock file in the django_app/

Remove the file from the /etc/nginx/sites-enabled/<file>
```
sudo rm /etc/nginx/sites-enabled/dj_boilerplate_landing

# Check that the remaining configs are valid:
sudo nginx -t 

sudo systemctl reload nginx

# Run certbot for the new domain
sudo certbot --nginx -d buildwebsite.io
```


&nbsp;


## Contact Me 📧
Hi, my name is George. 👋 I am a self taught developer and I want to help others build SaaS quickly, reliably and affordably.  

- Linode $60 credit: https://www.linode.com/lp/refer/?r=9ff0cd12e24c4e14bb041fd505242e605d1cc36d
- My Django + HTMX SaaS Boilerplate (Free): https://github.com/cangeorgecode/Django_Boilerplate_Free
- How-to, marketing, copywriting guide (no signup needed): https://joji.beehiiv.com
- X: @joji_jiji
  
